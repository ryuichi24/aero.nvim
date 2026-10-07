package main

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"
)

// Build the React UI with pnpm run build before compiling the Go bridge.
//
//go:embed web/dist
var bundledUI embed.FS

type config struct {
	Socket       string `json:"socket"`
	Bind         string `json:"bind"`
	Origin       string `json:"origin"`
	Cert         string `json:"cert,omitempty"`
	Key          string `json:"key,omitempty"`
	Port         int    `json:"port"`
	AllowHTTP    bool   `json:"allow_http"`
	DevicesFile  string `json:"devices_file,omitempty"`
	StdioControl bool   `json:"-"`
}

func loopback(host string) bool {
	return host == "localhost" || net.ParseIP(host).IsLoopback()
}

func (c config) validate() error {
	if c.Socket == "" {
		return errors.New("--socket is required")
	}
	if c.Port < 1 || c.Port > 65535 {
		return errors.New("--port must be between 1 and 65535")
	}
	if (c.Cert == "") != (c.Key == "") {
		return errors.New("HTTPS requires both --cert and --key")
	}
	if !loopback(c.Bind) && c.Cert == "" && !c.AllowHTTP {
		return errors.New("non-loopback binding requires HTTPS or explicit --allow-http")
	}
	u, err := url.Parse(c.Origin)
	scheme := "http"
	if c.Cert != "" {
		scheme = "https"
	}
	if err != nil || u.Scheme != scheme || u.Hostname() == "" || u.Path != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" || u.User != nil {
		return errors.New("--origin must be the exact HTTP(S) origin without a path")
	}
	if c.Cert == "" && !loopback(u.Hostname()) && !c.AllowHTTP {
		return errors.New("HTTP origins must be loopback unless --allow-http is explicitly enabled")
	}
	return nil
}

type bridge struct {
	state         *state
	ui            fs.FS
	pollInterval  time.Duration
	onChange      func(string)
	recordingsDir string
}

func newBridge(h host, origin string) *bridge {
	ui, err := fs.Sub(bundledUI, "web/dist")
	if err != nil {
		panic("embedded UI missing")
	}
	return &bridge{state: newState(h, origin), ui: ui, pollInterval: 500 * time.Millisecond}
}

func reply(w http.ResponseWriter, status int, data any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(data)
}

func reject(w http.ResponseWriter, status int, message string) {
	reply(w, status, map[string]string{"error": message})
}

func (b *bridge) protected(w http.ResponseWriter, r *http.Request) bool {
	u, _ := url.Parse(b.state.origin)
	if r.Host != u.Host {
		reject(w, http.StatusForbidden, "invalid host")
		return false
	}
	origin := r.Header.Get("Origin")
	if (r.Method == http.MethodPost && origin != b.state.origin) || (origin != "" && origin != b.state.origin) {
		reject(w, http.StatusForbidden, "invalid origin")
		return false
	}
	site := r.Header.Get("Sec-Fetch-Site")
	if site != "" && site != "same-origin" && site != "none" {
		reject(w, http.StatusForbidden, "cross-origin request rejected")
		return false
	}
	return true
}

func (b *bridge) authenticate(w http.ResponseWriter, r *http.Request) (device, string, bool) {
	cookie, err := r.Cookie(b.cookie("", 0).Name)
	if err == nil {
		if d, ok := b.state.authenticate(cookie.Value); ok {
			http.SetCookie(w, b.cookie(cookie.Value, deviceCookieAge))
			return d, cookie.Value, true
		}
	}
	reject(w, http.StatusUnauthorized, "pairing required or device revoked")
	return device{}, "", false
}

func (b *bridge) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	// Mermaid SVGs include generated styles and presentation style attributes.
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")
	if !b.protected(w, r) {
		return
	}
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Allow", "GET, POST")
		reject(w, http.StatusMethodNotAllowed, "unsupported method")
		return
	}
	if r.Method == http.MethodGet && !strings.HasPrefix(r.URL.Path, "/api/") {
		b.static(w, r)
		return
	}
	if r.URL.RawQuery != "" && !(r.Method == http.MethodGet && (r.URL.Path == "/api/image" || r.URL.Path == "/api/video")) {
		reject(w, http.StatusBadRequest, "query parameters are unsupported")
		return
	}
	if r.Method == http.MethodPost && r.URL.Path == "/api/pair" {
		b.pair(w, r)
		return
	}
	d, token, ok := b.authenticate(w, r)
	if !ok {
		return
	}
	if r.Method == http.MethodGet {
		switch r.URL.Path {
		case "/api/image":
			b.image(w, r)
		case "/api/video":
			b.video(w, r)
		case "/api/snapshot":
			reply(w, http.StatusOK, b.state.refresh(r.Context()))
		case "/api/events":
			b.events(w, r, token)
		default:
			reject(w, http.StatusNotFound, "unknown route")
		}
		return
	}
	if r.URL.Path == "/api/revoke" {
		var body map[string]json.RawMessage
		if !decodeBody(w, r, &body) {
			return
		}
		if err := b.state.revoke(d.ID); err != nil {
			reject(w, http.StatusServiceUnavailable, "could not persist device revocation")
			return
		}
		http.SetCookie(w, b.cookie("", -1))
		reply(w, http.StatusOK, map[string]string{"status": "revoked"})
		if b.onChange != nil {
			b.onChange("devices")
		}
		return
	}
	if r.URL.Path == "/api/source" || r.URL.Path == "/api/reports" {
		b.source(w, r)
		return
	}
	method := map[string]string{"/api/prompt": "prompt", "/api/cancel": "cancel", "/api/permission": "permission"}[r.URL.Path]
	for _, lifecycle := range []string{"session_assign_board", "session_create", "session_resume", "session_rename", "session_delete", "worktree_create", "worktree_rename", "worktree_delete"} {
		if r.URL.Path == "/api/"+lifecycle {
			method = lifecycle
		}
	}
	if method == "" {
		reject(w, http.StatusNotFound, "unknown route")
		return
	}
	var action struct {
		OperationID  string  `json:"operation_id"`
		Session      string  `json:"session"`
		Conversation string  `json:"conversation"`
		Text         string  `json:"text,omitempty"`
		Permission   string  `json:"permission,omitempty"`
		Option       string  `json:"option,omitempty"`
		Epoch        string  `json:"epoch,omitempty"`
		Target       string  `json:"target,omitempty"`
		Workspace    string  `json:"workspace,omitempty"`
		Worktree     string  `json:"worktree,omitempty"`
		Agent        string  `json:"agent,omitempty"`
		Name         *string `json:"name,omitempty"`
		Branch       string  `json:"branch,omitempty"`
		Force        bool    `json:"force,omitempty"`
		BoardID      string  `json:"board_id,omitempty"`
		Replace      bool    `json:"replace"`
	}
	if !decodeBody(w, r, &action) {
		return
	}
	if len(action.OperationID) < 16 || len(action.OperationID) > 128 {
		reject(w, http.StatusBadRequest, "operation_id required (16-128 characters)")
		return
	}
	// Reject oversized private-protocol messages before any host side effect.
	encoded, _ := json.Marshal(map[string]any{"method": method, "params": action})
	if len(encoded)+1 > maxRequest {
		reject(w, http.StatusBadRequest, "action exceeds the host protocol limit")
		return
	}
	response, err := b.state.host.Call(r.Context(), method, action)
	// ACP assignment finishes asynchronously; observe the same idempotent receipt.
	if method == "session_assign_board" && err == nil {
		deadline := time.Now().Add(5 * time.Second)
		for response.Error == "" && time.Now().Before(deadline) {
			var receipt struct {
				Status string `json:"status"`
			}
			if json.Unmarshal(response.Result, &receipt) != nil || receipt.Status != "unknown" {
				break
			}
			select {
			case <-r.Context().Done():
				err = r.Context().Err()
			case <-time.After(50 * time.Millisecond):
				response, err = b.state.host.Call(r.Context(), method, action)
			}
			if err != nil {
				break
			}
		}
	}
	if err != nil {
		reject(w, http.StatusServiceUnavailable, "Neovim disconnected; outcome unknown. Retry the identical operation.")
		return
	}
	status := http.StatusOK
	if response.Error != "" {
		status = http.StatusConflict
		if strings.Contains(response.Error, "outcome unknown") {
			status = http.StatusServiceUnavailable
		}
	}
	reply(w, status, response)
}

func decodeBody(w http.ResponseWriter, r *http.Request, target any) bool {
	media, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || media != "application/json" {
		reject(w, http.StatusBadRequest, "invalid JSON body")
		return false
	}
	r.Body = http.MaxBytesReader(w, r.Body, maxRequest)
	// A null body must not silently decode to a zero-value action or revocation.
	raw, err := io.ReadAll(r.Body)
	if err != nil || !strings.HasPrefix(strings.TrimSpace(string(raw)), "{") {
		reject(w, http.StatusBadRequest, "invalid JSON body")
		return false
	}
	decoder := json.NewDecoder(strings.NewReader(string(raw)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		reject(w, http.StatusBadRequest, "invalid JSON body")
		return false
	}
	if decoder.Decode(new(any)) != io.EOF {
		reject(w, http.StatusBadRequest, "invalid JSON body")
		return false
	}
	return true
}

const deviceCookieAge = 365 * 24 * 60 * 60

func (b *bridge) cookie(token string, maxAge int) *http.Cookie {
	hash := sha256.Sum256([]byte(b.state.origin))
	cookie := &http.Cookie{Name: fmt.Sprintf("aero_device_%x", hash[:8]), Value: token, Path: "/", HttpOnly: true,
		SameSite: http.SameSiteStrictMode, Secure: strings.HasPrefix(b.state.origin, "https://"), MaxAge: maxAge}
	if maxAge > 0 {
		cookie.Expires = time.Now().Add(time.Duration(maxAge) * time.Second)
	}
	return cookie
}

func (b *bridge) pair(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Code string  `json:"code"`
		Name *string `json:"name"`
	}
	if !decodeBody(w, r, &input) {
		return
	}
	name := "Phone"
	if input.Name != nil {
		name = *input.Name
	}
	token, d, err := b.state.pair(input.Code, name)
	if err != nil {
		if errors.Is(err, errPairingDenied) {
			reject(w, http.StatusUnauthorized, errPairingDenied.Error())
		} else {
			reject(w, http.StatusServiceUnavailable, "could not remember this device; pairing was not completed")
		}
		return
	}
	http.SetCookie(w, b.cookie(token, deviceCookieAge))
	reply(w, http.StatusOK, map[string]string{"device": d.ID})
	if b.onChange != nil {
		b.onChange("paired")
	}
}

func (b *bridge) events(w http.ResponseWriter, r *http.Request, token string) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	controller := http.NewResponseController(w)
	cursor := ""
	ticker := time.NewTicker(b.pollInterval)
	defer ticker.Stop()
	for {
		if _, ok := b.state.authenticate(token); !ok {
			return
		}
		snapshot := b.state.refresh(r.Context())
		// Revocation during a slow host read must also stop this stream.
		if _, ok := b.state.authenticate(token); !ok || r.Context().Err() != nil {
			return
		}
		_ = controller.SetWriteDeadline(time.Now().Add(10 * time.Second))
		current := string(snapshot["cursor"])
		if current != cursor {
			cursor = current
			var id string
			_ = json.Unmarshal(snapshot["cursor"], &id)
			encoded, _ := json.Marshal(snapshot)
			if _, err := io.WriteString(w, "id: "+id+"\ndata: "+string(encoded)+"\n\n"); err != nil {
				return
			}
		} else if _, err := io.WriteString(w, ": heartbeat\n\n"); err != nil {
			return
		}
		if err := controller.Flush(); err != nil {
			return
		}
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
		}
	}
}

func (b *bridge) static(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/")
	if name == "" {
		name = "index.html"
	}
	if !fs.ValidPath(name) || (name != "index.html" && name != "manifest.webmanifest" && !strings.HasPrefix(name, "assets/")) {
		reject(w, http.StatusNotFound, "unknown route")
		return
	}
	data, err := fs.ReadFile(b.ui, name)
	if err != nil {
		reject(w, http.StatusNotFound, "unknown route")
		return
	}
	typeName := mime.TypeByExtension(path.Ext(name))
	if name == "manifest.webmanifest" {
		typeName = "application/manifest+json"
	}
	w.Header().Set("Content-Type", typeName)
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func httpServer(c config, handler http.Handler, ctx context.Context) *http.Server {
	return &http.Server{
		Addr: net.JoinHostPort(c.Bind, strconv.Itoa(c.Port)), Handler: handler,
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 10 * time.Second, IdleTimeout: 60 * time.Second,
		TLSConfig:   &tls.Config{MinVersion: tls.VersionTLS12},
		BaseContext: func(net.Listener) context.Context { return ctx },
		// Do not expose credentials or request details through HTTP server logs.
		ErrorLog: log.New(io.Discard, "", 0),
	}
}
