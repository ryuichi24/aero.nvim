package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"io/fs"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

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
	// Source folding compiles Tree-sitter WASM in a worker, which inherits this policy.
	w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'")

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
			reply(w, http.StatusOK, b.state.cachedSnapshot(r.Context(), b.pollInterval))
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

	if r.URL.Path == "/api/git/status" || r.URL.Path == "/api/git/diff" {
		b.git(w, r)
		return
	}

	if r.URL.Path == "/api/source" || r.URL.Path == "/api/reports" || r.URL.Path == "/api/reference" {
		b.source(w, r)
		return
	}

	if r.URL.Path == "/api/reference_browse" || r.URL.Path == "/api/prompt_snippets" || r.URL.Path == "/api/submodule_browse" {
		var input struct {
			Epoch        string `json:"epoch"`
			Target       string `json:"target"`
			Worktree     string `json:"worktree"`
			Path         string `json:"path"`
			Session      string `json:"session"`
			Conversation string `json:"conversation"`
			Refresh      bool   `json:"refresh"`
		}
		if !decodeBody(w, r, &input) {
			return
		}

		method := "reference_browse"

		if r.URL.Path == "/api/prompt_snippets" {
			method = "prompt_snippets"
		} else if r.URL.Path == "/api/submodule_browse" {
			method = "submodule_browse"
		}

		b.forwardHostRead(w, r, method, input)

		return
	}

	method := map[string]string{"/api/prompt": "prompt", "/api/cancel": "cancel", "/api/permission": "permission"}[r.URL.Path]

	for _, lifecycle := range []string{"reference_update", "reference_cancel", "session_assign_board", "session_create", "session_update", "session_resume", "session_rename", "session_delete", "worktree_create", "worktree_rename", "worktree_delete"} {
		if r.URL.Path == "/api/"+lifecycle {
			method = lifecycle
		}
	}

	if method == "" {
		reject(w, http.StatusNotFound, "unknown route")
		return
	}

	var action struct {
		OperationID     string  `json:"operation_id"`
		Session         string  `json:"session"`
		Conversation    string  `json:"conversation"`
		Text            string  `json:"text,omitempty"`
		Permission      string  `json:"permission,omitempty"`
		Option          string  `json:"option,omitempty"`
		Epoch           string  `json:"epoch,omitempty"`
		Target          string  `json:"target,omitempty"`
		Workspace       string  `json:"workspace,omitempty"`
		Worktree        string  `json:"worktree,omitempty"`
		Agent           string  `json:"agent,omitempty"`
		Scope           string  `json:"scope,omitempty"`
		Field           string  `json:"field,omitempty"`
		Value           *bool   `json:"value,omitempty"`
		Name            *string `json:"name,omitempty"`
		Branch          string  `json:"branch,omitempty"`
		Force           bool    `json:"force,omitempty"`
		BoardID         string  `json:"board_id,omitempty"`
		Replace         bool    `json:"replace"`
		ReferenceAction string  `json:"reference_action,omitempty"`
		TransferID      string  `json:"transfer_id,omitempty"`
		Path            string  `json:"path,omitempty"`
		Items           []struct {
			Path   string `json:"path"`
			Action string `json:"action"`
		} `json:"items,omitempty"`
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
	defer b.state.invalidateSnapshot()
	// ACP assignments and reference transfers finish asynchronously; observe the
	// same idempotent receipt without re-running their side effects.
	if (method == "session_assign_board" || method == "reference_update") && err == nil {
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
