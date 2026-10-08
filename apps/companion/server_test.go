package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

type hostFunc func(context.Context, string, any) (hostResponse, error)

func TestLifecycleRoutes(t *testing.T) {
	for _, method := range []string{"session_create", "session_resume", "session_rename", "session_delete", "worktree_create", "worktree_rename", "worktree_delete"} {
		t.Run(method, func(t *testing.T) {
			calls := 0
			c := newClient(t, hostFunc(func(_ context.Context, got string, params any) (hostResponse, error) {
				calls++
				if got != method {
					t.Errorf("method = %s", got)
				}
				encoded, _ := json.Marshal(params)
				var data map[string]any
				_ = json.Unmarshal(encoded, &data)
				if data["epoch"] != "host" || data["target"] != "target" || data["name"] != "Phone" {
					t.Errorf("lost lifecycle fields: %s", encoded)
				}
				return hostResponse{Result: json.RawMessage(`{"status":"accepted"}`)}, nil
			}))
			data := map[string]any{"operation_id": "lifecycle-route-0001", "epoch": "host", "target": "target", "name": "Phone", "workspace": "/repo", "worktree": "/repo/feature", "agent": "fixture", "branch": "feature", "force": true}
			c.json("POST", "/api/"+method, data, http.StatusUnauthorized)
			if calls != 0 {
				t.Fatal("unauthenticated lifecycle reached host")
			}
			c.pair()
			c.json("POST", "/api/"+method, data, http.StatusOK)
			if calls != 1 {
				t.Fatalf("host calls = %d", calls)
			}
		})
	}
}

func (f hostFunc) Call(ctx context.Context, method string, params any) (hostResponse, error) {
	return f(ctx, method, params)
}

func fixtureHost(t *testing.T) unixHost {
	t.Helper()
	if _, err := exec.LookPath("nvim"); err != nil {
		t.Fatal("companion integration tests require Neovim")
	}
	directory := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	command := exec.CommandContext(ctx, "nvim", "--headless", "-u", "NONE", "-l", "tests/fixtures/companion_host.lua")
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	command.Dir = filepath.Dir(filepath.Dir(cwd))
	command.Env = append(os.Environ(), "AERO_COMPANION_TEST_DIR="+directory)
	command.Stdout, command.Stderr = io.Discard, io.Discard
	if err := command.Start(); err != nil {
		cancel()
		t.Fatal(err)
	}
	t.Cleanup(func() { cancel(); _ = command.Wait() })
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		if data, err := os.ReadFile(filepath.Join(directory, "socket-path")); err == nil {
			return unixHost{path: strings.TrimSpace(string(data))}
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("Neovim companion fixture did not become ready")
	return unixHost{}
}

type testClient struct {
	t      *testing.T
	server *httptest.Server
	bridge *bridge
	cookie *http.Cookie
}

func newClient(t *testing.T, h host) *testClient {
	t.Helper()
	b := newBridge(h, "http://localhost:8765")
	b.pollInterval = 20 * time.Millisecond
	server := httptest.NewServer(b)
	b.state.origin = server.URL
	t.Cleanup(server.Close)
	return &testClient{t: t, server: server, bridge: b}
}

func (c *testClient) request(method, path string, data any, origin string) *http.Response {
	c.t.Helper()
	var body io.Reader
	if data != nil {
		encoded, err := json.Marshal(data)
		if err != nil {
			c.t.Fatal(err)
		}
		body = bytes.NewReader(encoded)
	}
	r, err := http.NewRequest(method, c.server.URL+path, body)
	if err != nil {
		c.t.Fatal(err)
	}
	if origin == "" {
		origin = c.bridge.state.origin
	}
	r.Header.Set("Origin", origin)
	if data != nil {
		r.Header.Set("Content-Type", "application/json")
	}
	if c.cookie != nil {
		r.AddCookie(c.cookie)
	}
	response, err := (&http.Client{Timeout: 10 * time.Second}).Do(r)
	if err != nil {
		c.t.Fatal(err)
	}
	return response
}

func (c *testClient) json(method, path string, data any, status int) map[string]any {
	c.t.Helper()
	response := c.request(method, path, data, "")
	defer response.Body.Close()
	if response.StatusCode != status {
		body, _ := io.ReadAll(response.Body)
		c.t.Fatalf("%s %s: status %d, wanted %d: %s", method, path, response.StatusCode, status, body)
	}
	var result map[string]any
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		c.t.Fatal(err)
	}
	return result
}

func (c *testClient) pair() string {
	c.t.Helper()
	code := c.bridge.state.newPairingCode()
	response := c.request("POST", "/api/pair", map[string]string{"code": code, "name": "Test phone"}, "")
	defer response.Body.Close()
	if response.StatusCode != 200 {
		c.t.Fatal("pairing failed:", response.StatusCode)
	}
	c.cookie = response.Cookies()[0]
	if !c.cookie.HttpOnly || c.cookie.SameSite != http.SameSiteStrictMode {
		c.t.Fatal("device cookie protections missing")
	}
	var body struct{ Device string }
	if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
		c.t.Fatal(err)
	}
	return body.Device
}

func scanEvents(response *http.Response) *bufio.Scanner {
	scanner := bufio.NewScanner(response.Body)
	scanner.Buffer(make([]byte, 4096), maxResponse)
	return scanner
}

func event(t *testing.T, scanner *bufio.Scanner) map[string]any {
	t.Helper()
	for scanner.Scan() {
		if text := scanner.Text(); strings.HasPrefix(text, "data: ") {
			var snapshot map[string]any
			if err := json.Unmarshal([]byte(strings.TrimPrefix(text, "data: ")), &snapshot); err != nil {
				t.Fatal(err)
			}
			return snapshot
		}
	}
	t.Fatalf("stream ended before event: %v", scanner.Err())
	return nil
}

func firstSession(snapshot map[string]any) map[string]any {
	return snapshot["sessions"].([]any)[0].(map[string]any)
}

func action(session map[string]any, text string) map[string]any {
	return map[string]any{"operation_id": randomToken(24), "session": session["id"],
		"conversation": session["conversation"], "text": text}
}

func fakeSnapshot(context.Context, string, any) (hostResponse, error) {
	return hostResponse{Result: json.RawMessage(`{"sessions":[],"inbox":[],"workspaces":[],"worktrees":[]}`)}, nil
}

func TestAuthenticationPairingRevocationAndOrigins(t *testing.T) {
	c := newClient(t, hostFunc(fakeSnapshot))
	c.json("GET", "/api/snapshot", nil, 401)
	c.json("POST", "/api/pair", map[string]string{"code": "無効"}, 401)
	code := c.bridge.state.code
	response := c.request("POST", "/api/pair", map[string]string{"code": code}, "")
	if response.StatusCode != 200 {
		t.Fatal(response.StatusCode)
	}
	response.Body.Close()
	c.json("POST", "/api/pair", map[string]string{"code": code}, 401)
	id := c.pair()
	c.json("GET", "/api/snapshot", nil, 200)
	for _, path := range []string{"/api/events", "/api/cancel"} {
		method := "GET"
		var data any
		if path == "/api/cancel" {
			method, data = "POST", map[string]string{}
		}
		response := c.request(method, path, data, "https://evil.example")
		response.Body.Close()
		if response.StatusCode != 403 {
			t.Fatal("cross-origin access accepted")
		}
	}
	for _, header := range []string{"Host", "Origin", "Sec-Fetch-Site"} {
		r := httptest.NewRequest("POST", c.server.URL+"/api/cancel", strings.NewReader("{}"))
		r.Header.Set("Origin", c.server.URL)
		r.AddCookie(c.cookie)
		if header == "Host" {
			r.Host = "evil.example"
		} else if header == "Origin" {
			r.Header.Del("Origin")
		} else {
			r.Header.Set(header, "cross-site")
		}
		w := httptest.NewRecorder()
		c.bridge.ServeHTTP(w, r)
		if w.Code != 403 {
			t.Fatalf("%s protection failed", header)
		}
	}
	stream := c.request("GET", "/api/events", nil, "")
	scanner := scanEvents(stream)
	if !event(t, scanner)["connected"].(bool) {
		t.Fatal("missing live snapshot")
	}
	c.bridge.state.revoke(id)
	for scanner.Scan() {
		if strings.HasPrefix(scanner.Text(), "data:") {
			t.Fatal("stream continued after revocation")
		}
	}
	stream.Body.Close()
	c.json("GET", "/api/snapshot", nil, 401)
	c.json("POST", "/api/prompt", map[string]string{}, 401)
	c.bridge.state.newPairingCode()
	c.bridge.state.codeExpires = time.Time{}
	c.json("POST", "/api/pair", map[string]string{"code": c.bridge.state.code}, 401)
	c.bridge.state.newPairingCode()
	for range 20 {
		c.json("POST", "/api/pair", map[string]string{"code": "wrong"}, 401)
	}
	c.json("POST", "/api/pair", map[string]string{"code": c.bridge.state.code}, 401)
}

func TestStreamReconnectPromptRetryPermissionAndCancel(t *testing.T) {
	c := newClient(t, fixtureHost(t))
	c.pair()
	stream := c.request("GET", "/api/events", nil, "")
	scanner := scanEvents(stream)
	initial := event(t, scanner)
	args := action(firstSession(initial), "permission")
	receipt := c.json("POST", "/api/prompt", args, 200)
	if receipt["result"].(map[string]any)["status"] != "accepted" {
		t.Fatal(receipt)
	}
	retried := c.json("POST", "/api/prompt", args, 200)
	if retried["result"].(map[string]any)["status"] != "accepted" {
		t.Fatal(retried)
	}
	var snapshot map[string]any
	for range 50 {
		snapshot = event(t, scanner)
		if firstSession(snapshot)["permission"] != nil {
			break
		}
	}
	permission := firstSession(snapshot)["permission"].(map[string]any)
	if len(snapshot["inbox"].([]any)) != 1 {
		t.Fatal("permission inbox event missing or duplicated")
	}
	stream.Body.Close()
	stream = c.request("GET", "/api/events", nil, "")
	defer stream.Body.Close()
	scanner = scanEvents(stream)
	resync := event(t, scanner)
	if resync["cursor"] != snapshot["cursor"] {
		t.Fatal("reconnect did not resynchronize to the current cursor")
	}
	queued := action(firstSession(resync), "queued followup")
	if c.json("POST", "/api/prompt", queued, 200)["result"].(map[string]any)["status"] != "queued" {
		t.Fatal("busy prompt was not queued")
	}
	answer := action(firstSession(resync), "")
	answer["permission"], answer["option"] = permission["id"], "allow"
	c.json("POST", "/api/permission", answer, 200)
	c.json("POST", "/api/permission", answer, 200)
	answer["operation_id"] = randomToken(24)
	c.json("POST", "/api/permission", answer, 409)
	stale := action(firstSession(resync), "")
	stale["conversation"] = "stale"
	c.json("POST", "/api/cancel", stale, 409)
	var final map[string]any
	for range 100 {
		final = event(t, scanner)
		if firstSession(final)["status"] == "idle" {
			break
		}
	}
	encoded, _ := json.Marshal(final)
	if !bytes.Contains(encoded, []byte("Permission answered: allow")) || !bytes.Contains(encoded, []byte("Streamed response: queued followup")) {
		t.Fatal("permission choice or queued prompt did not reach the agent")
	}
	c.json("POST", "/api/prompt", action(firstSession(final), "hold"), 200)
	for range 50 {
		snapshot = event(t, scanner)
		if firstSession(snapshot)["permission"] != nil {
			break
		}
	}
	c.json("POST", "/api/cancel", action(firstSession(snapshot), ""), 200)
	for range 50 {
		snapshot = event(t, scanner)
		if firstSession(snapshot)["status"] == "idle" {
			break
		}
	}
	if firstSession(snapshot)["permission"] != nil {
		t.Fatal("cancel did not clear permission")
	}
}

func TestLostReplyRetryAfterBridgeRestart(t *testing.T) {
	h := fixtureHost(t)
	var once sync.Once
	lost := hostFunc(func(ctx context.Context, method string, params any) (hostResponse, error) {
		response, err := h.Call(ctx, method, params)
		if method == "prompt" {
			once.Do(func() { err = errors.New("response lost after acceptance") })
		}
		return response, err
	})
	c := newClient(t, lost)
	c.pair()
	args := action(firstSession(c.json("GET", "/api/snapshot", nil, 200)), "lost-reply-unique-prompt")
	c.json("POST", "/api/prompt", args, 503)
	// A new HTTP bridge/device must still use Neovim's original receipt.
	c2 := newClient(t, h)
	c2.pair()
	c2.json("POST", "/api/prompt", args, 200)
	changed := make(map[string]any)
	for key, value := range args {
		changed[key] = value
	}
	changed["text"] = "changed"
	c2.json("POST", "/api/prompt", changed, 409)
	var snapshot map[string]any
	for range 50 {
		snapshot = c2.json("GET", "/api/snapshot", nil, 200)
		if firstSession(snapshot)["status"] == "idle" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	copies := 0
	for _, raw := range firstSession(snapshot)["blocks"].([]any) {
		block := raw.(map[string]any)
		if block["kind"] == "user" && block["text"] == args["text"] {
			copies++
		}
	}
	if copies != 1 {
		t.Fatalf("lost-response retry submitted %d copies", copies)
	}
}

func TestHTTPSConfigurationAndUnavailableHost(t *testing.T) {
	base := config{Socket: "/private/socket", Bind: "127.0.0.1", Port: 8765, Origin: "http://localhost:8765"}
	if err := base.validate(); err != nil {
		t.Fatal(err)
	}
	invalid := []config{
		{Socket: base.Socket, Bind: "0.0.0.0", Port: 8765, Origin: "http://192.168.1.5:8765"},
		{Socket: base.Socket, Bind: base.Bind, Port: 8765, Origin: "http://localhost:8765/"},
		{Socket: base.Socket, Bind: base.Bind, Port: 8765, Origin: "http://remote.example:8765"},
		{Socket: base.Socket, Bind: base.Bind, Port: 8765, Origin: "https://localhost:8765", Cert: "cert"},
	}
	for _, c := range invalid {
		if c.validate() == nil {
			t.Fatalf("unsafe config accepted: %+v", c)
		}
	}
	secure := config{Socket: base.Socket, Bind: "0.0.0.0", Port: 8765, Origin: "https://aero.example:8765", Cert: "cert", Key: "key"}
	if err := secure.validate(); err != nil {
		t.Fatal(err)
	}
	b := newBridge(hostFunc(fakeSnapshot), secure.Origin)
	if !b.cookie("test", 0).Secure {
		t.Fatal("HTTPS device cookie is not Secure")
	}
	https := httptest.NewTLSServer(b)
	defer https.Close()
	b.state.origin = https.URL
	r, _ := http.NewRequest("POST", https.URL+"/api/pair", strings.NewReader(`{"code":"`+b.state.code+`"}`))
	r.Header.Set("Origin", https.URL)
	r.Header.Set("Content-Type", "application/json")
	response, err := https.Client().Do(r)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 200 || !response.Cookies()[0].Secure {
		t.Fatal("HTTPS pairing failed")
	}
	c := newClient(t, unixHost{path: "/nonexistent-aero-companion.sock"})
	c.pair()
	if c.json("GET", "/api/snapshot", nil, 200)["connected"] != false {
		t.Fatal("unavailable host reported connected")
	}
	c.json("POST", "/api/prompt", map[string]string{"operation_id": randomToken(24)}, 503)
}

func TestEmbeddedReactAssetsAndNarrowRoutes(t *testing.T) {
	c := newClient(t, hostFunc(fakeSnapshot))
	response := c.request("GET", "/", nil, "")
	policy := response.Header.Get("Content-Security-Policy")
	if !strings.Contains(policy, "style-src 'self' 'unsafe-inline';") || !strings.Contains(policy, "script-src 'self' 'wasm-unsafe-eval';") {
		t.Fatal("embedded UI must allow Mermaid styles and Tree-sitter WASM while restricting scripts to self")
	}
	data, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != 200 || !bytes.Contains(data, []byte(`id="root"`)) || !bytes.Contains(data, []byte(`/assets/`)) {
		t.Fatal("built React entry point is not embedded")
	}
	workers, err := fs.Glob(c.bridge.ui, "assets/source-folds.worker-*.js")
	if err != nil || len(workers) == 0 {
		t.Fatal("source folding worker is not embedded")
	}
	response = c.request("GET", "/"+workers[0], nil, "")
	response.Body.Close()
	if response.StatusCode != http.StatusOK || response.Header.Get("Content-Security-Policy") != policy {
		t.Fatal("source folding worker must receive the WASM-enabled policy")
	}
	c.pair()
	c.json("POST", "/api/nvim_exec_lua", map[string]string{"code": "evil"}, 404)
	c.json("GET", "/api/snapshot?credential=never", nil, 400)
	response = c.request("POST", "/api/prompt", map[string]string{"operation_id": randomToken(24), "text": strings.Repeat("x", maxRequest)}, "")
	response.Body.Close()
	if response.StatusCode != 400 {
		t.Fatal("oversized body accepted")
	}
}

func TestPrivateNetworkHTTPPreservesAuthenticationAndOrigins(t *testing.T) {
	c := config{Socket: "/private/socket", Bind: "100.101.102.103", Port: 8765, Origin: "http://aero.tailnet.ts.net:8765", AllowHTTP: true}
	if err := c.validate(); err != nil {
		t.Fatal(err)
	}
	b := newBridge(hostFunc(fakeSnapshot), c.Origin)
	request := func(method, path, origin, body string, cookie *http.Cookie) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, c.Origin+path, strings.NewReader(body))
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		if body != "" {
			r.Header.Set("Content-Type", "application/json")
		}
		if cookie != nil {
			r.AddCookie(cookie)
		}
		w := httptest.NewRecorder()
		b.ServeHTTP(w, r)
		return w
	}
	if request("GET", "/api/snapshot", "", "", nil).Code != 401 {
		t.Fatal("HTTP opt-in bypassed auth")
	}
	pair := request("POST", "/api/pair", c.Origin, `{"code":"`+b.state.code+`"}`, nil)
	if pair.Code != 200 {
		t.Fatal("private-network HTTP pairing failed")
	}
	cookie := pair.Result().Cookies()[0]
	if cookie.Secure || !cookie.HttpOnly || cookie.SameSite != http.SameSiteStrictMode {
		t.Fatal("HTTP pairing cookie attributes are incorrect")
	}
	if request("GET", "/api/snapshot", "", "", cookie).Code != 200 {
		t.Fatal("paired HTTP snapshot failed")
	}
	if request("GET", "/api/events", "https://evil.example", "", cookie).Code != 403 {
		t.Fatal("HTTP stream origin bypass")
	}
	if request("POST", "/api/cancel", "http://evil.example", `{}`, cookie).Code != 403 {
		t.Fatal("HTTP action origin bypass")
	}
	if request("POST", "/api/revoke", c.Origin, `{}`, cookie).Code != 200 {
		t.Fatal("HTTP revocation failed")
	}
	if request("GET", "/api/snapshot", "", "", cookie).Code != 401 {
		t.Fatal("HTTP device remained authorized after revocation")
	}
}

// Opt-in fixture for manual/Playwright phone verification; never used in production.
func TestBrowserFixture(t *testing.T) {
	if os.Getenv("AERO_COMPANION_BROWSER_FIXTURE") != "1" {
		t.Skip("set AERO_COMPANION_BROWSER_FIXTURE=1 to run the localhost demo")
	}
	port := 8765
	if value := os.Getenv("AERO_COMPANION_BROWSER_PORT"); value != "" {
		var err error
		port, err = strconv.Atoi(value)
		if err != nil || port < 1 || port > 65535 {
			t.Fatal("invalid browser fixture port")
		}
	}
	origin := "http://localhost:" + strconv.Itoa(port)
	b := newBridge(fixtureHost(t), origin)
	b.state.code = "123456"
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()
	server := httpServer(config{Bind: "127.0.0.1", Port: port}, b, ctx)
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		t.Fatal(err)
	}
	go func() { <-ctx.Done(); _ = server.Close() }()
	t.Log("Browser fixture: " + origin + " — code: 123456")
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		t.Fatal(err)
	}
}
