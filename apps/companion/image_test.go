package main

import (
	"context"
	"encoding/json"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func TestScreenshotImages(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	png := []byte("\x89PNG\r\n\x1a\nimage fixture")
	external := filepath.Join(outside, "shot.png")
	for _, name := range []string{filepath.Join(root, "shot.png"), external} {
		if err := os.WriteFile(name, png, 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(external, filepath.Join(root, "escape.png")); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(map[string]any{"sessions": []any{map[string]any{"id": "one", "worktree": root, "blocks": []any{map[string]string{"text": "[Screenshot](" + external + ")"}}}}})
	c := newClient(t, hostFunc(func(context.Context, string, any) (hostResponse, error) { return hostResponse{Result: data}, nil }))
	check := func(name string, status int) {
		t.Helper()
		response := c.request("GET", "/api/image?"+url.Values{"session": {"one"}, "path": {name}}.Encode(), nil, "")
		defer response.Body.Close()
		if response.StatusCode != status {
			t.Fatalf("%s: status %d, want %d", name, response.StatusCode, status)
		}
		if status == 200 {
			body, _ := io.ReadAll(response.Body)
			if string(body) != string(png) || response.Header.Get("Content-Type") != "image/png" {
				t.Fatal("image response mismatch")
			}
		}
	}
	check("shot.png", 401)
	c.pair()
	check("shot.png", 200)
	check("file://"+external, 200)
	check(filepath.Join(outside, "unlinked.png"), 403)
	check("../shot.png", 403)
	check("escape.png", 404)
}
