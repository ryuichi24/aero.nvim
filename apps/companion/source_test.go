package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

func TestSourceBrowsing(t *testing.T) {
	root := t.TempDir()
	outside := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte("package main\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "binary"), []byte{0, 1}, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}
	data, _ := json.Marshal(map[string]any{"sessions": []any{}, "worktrees": []any{map[string]string{"path": root}}})
	c := newClient(t, hostFunc(func(context.Context, string, any) (hostResponse, error) { return hostResponse{Result: data}, nil }))
	request := func(tree, path string, status int) {
		c.json("POST", "/api/source", map[string]string{"worktree": tree, "path": path}, status)
	}
	request(root, "", http.StatusUnauthorized)
	c.pair()
	request(root, "", http.StatusOK)
	request(root, "main.go", http.StatusOK)
	request(outside, "", http.StatusForbidden)
	request(root, "../", http.StatusBadRequest)
	request(root, outside, http.StatusBadRequest)
	request(root, "escape", http.StatusNotFound)
	request(root, "binary", http.StatusBadRequest)
}

func TestReportBrowsing(t *testing.T) {
	worktree := t.TempDir()
	reports := t.TempDir()
	for name, body := range map[string]string{"findings.md": "# Findings\n", "secret.txt": "private"} {
		if err := os.WriteFile(filepath.Join(reports, name), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	data, _ := json.Marshal(map[string]any{"sessions": []any{}, "worktrees": []any{map[string]string{"path": worktree, "reports_directory": reports}}})
	c := newClient(t, hostFunc(func(context.Context, string, any) (hostResponse, error) { return hostResponse{Result: data}, nil }))
	request := func(tree, path string, status int) {
		c.json("POST", "/api/reports", map[string]string{"worktree": tree, "path": path}, status)
	}
	request(worktree, "", http.StatusUnauthorized)
	c.pair()
	request(worktree, "", http.StatusOK)
	request(worktree, "findings.md", http.StatusOK)
	listing := c.json("POST", "/api/reports", map[string]string{"worktree": worktree}, http.StatusOK)
	entries := listing["entries"].([]any)
	if len(entries) != 1 || entries[0].(map[string]any)["name"] != "findings.md" {
		t.Fatalf("unexpected report listing: %v", listing)
	}
	content := c.json("POST", "/api/reports", map[string]string{"worktree": worktree, "path": "findings.md"}, http.StatusOK)
	if content["content"] != "# Findings\n" {
		t.Fatalf("unexpected report content: %v", content)
	}
	request(reports, "", http.StatusForbidden)
	request(worktree, "secret.txt", http.StatusBadRequest)
	request(worktree, "../findings.md", http.StatusBadRequest)
	request(worktree, "nested/findings.md", http.StatusBadRequest)
	request(worktree, "missing.md", http.StatusNotFound)
}
