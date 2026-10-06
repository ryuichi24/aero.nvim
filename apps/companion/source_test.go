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
