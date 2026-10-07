package main

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func TestRecordings(t *testing.T) {
	root, outside, storage := t.TempDir(), t.TempDir(), t.TempDir()
	video := append([]byte{0x1a, 0x45, 0xdf, 0xa3}, bytes.Repeat([]byte("webm"), 200)...)
	name := filepath.Join(outside, "recording.webm")
	if err := os.WriteFile(name, video, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "fake.webm"), []byte("not a video"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(name, filepath.Join(root, "escape.webm")); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(map[string]any{"sessions": []any{map[string]any{"id": "one", "worktree": root, "blocks": []any{map[string]string{"text": "[Recording](" + name + ")"}}}}})
	h := hostFunc(func(context.Context, string, any) (hostResponse, error) { return hostResponse{Result: data}, nil })
	c := newClient(t, h)
	c.bridge.recordingsDir = storage
	path := "/api/video?" + url.Values{"session": {"one"}, "path": {name}}.Encode()
	res := c.request("GET", path, nil, "")
	res.Body.Close()
	if res.StatusCode != 401 {
		t.Fatal("unauthenticated recording accessible")
	}
	c.pair()
	check := func(client *testClient, path, byteRange string, status int) *http.Response {
		t.Helper()
		request, _ := http.NewRequest("GET", client.server.URL+path, nil)
		request.AddCookie(client.cookie)
		if byteRange != "" {
			request.Header.Set("Range", byteRange)
		}
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { response.Body.Close() })
		if response.StatusCode != status {
			body, _ := io.ReadAll(response.Body)
			t.Fatalf("status %d, want %d: %s", response.StatusCode, status, body)
		}
		return response
	}
	res = check(c, path, "bytes=0-3", 206)
	body, _ := io.ReadAll(res.Body)
	if !bytes.Equal(body, video[:4]) || res.Header.Get("Content-Type") != "video/webm" || res.Header.Get("Accept-Ranges") != "bytes" {
		t.Fatal("video range response mismatch")
	}
	entries, _ := os.ReadDir(storage)
	if len(entries) != 1 {
		t.Fatal("recording was not preserved")
	}
	if err := os.Remove(name); err != nil {
		t.Fatal(err)
	}
	// A fresh bridge can replay the private archive after the original is gone.
	restarted := newBridge(h, c.bridge.state.origin)
	restarted.recordingsDir = storage
	restarted.state.devices = c.bridge.state.copyDevices()
	request := httptest.NewRequest("GET", c.server.URL+path, nil)
	request.AddCookie(c.cookie)
	request.Header.Set("Range", "bytes=4-11")
	recorder := httptest.NewRecorder()
	restarted.ServeHTTP(recorder, request)
	if recorder.Code != 206 || !bytes.Equal(recorder.Body.Bytes(), video[4:12]) {
		t.Fatal("saved recording could not be replayed after restart")
	}
	for _, item := range []struct {
		path   string
		status int
	}{
		{"../escape.webm", 403}, {"escape.webm", 404}, {"fake.webm", 400}, {filepath.Join(outside, "unlinked.webm"), 403},
	} {
		check(c, "/api/video?"+url.Values{"session": {"one"}, "path": {item.path}}.Encode(), "", item.status)
	}
	check(c, path, "bytes=999999-", 416)
}
