package main

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGitBrowsing(t *testing.T) {
	tree := t.TempDir()
	git := func(args ...string) {
		t.Helper()
		if _, err := runGit(context.Background(), tree, args...); err != nil {
			t.Fatal(err)
		}
	}
	write := func(name, content string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(tree, name), []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	git("init")
	write("code.txt", "original\n")
	git("add", "code.txt")
	git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "initial")
	write("code.txt", "staged\n")
	git("add", "code.txt")
	write("code.txt", "unstaged\n")
	write("new file.txt", "new\n")
	data, _ := json.Marshal(map[string]any{"sessions": []any{}, "worktrees": []any{map[string]string{"path": tree}}})
	c := newClient(t, hostFunc(func(context.Context, string, any) (hostResponse, error) { return hostResponse{Result: data}, nil }))
	c.json("POST", "/api/git/status", map[string]any{"worktree": tree}, http.StatusUnauthorized)
	c.pair()
	status := c.json("POST", "/api/git/status", map[string]any{"worktree": tree}, http.StatusOK)
	if len(status["entries"].([]any)) != 2 {
		t.Fatalf("unexpected status: %v", status)
	}
	for _, staged := range []bool{true, false} {
		diff := c.json("POST", "/api/git/diff", map[string]any{"worktree": tree, "path": "code.txt", "staged": staged}, http.StatusOK)["content"].(string)
		expected := "+unstaged"
		if staged {
			expected = "+staged"
		}
		if !strings.Contains(diff, expected) {
			t.Fatalf("unexpected diff: %s", diff)
		}
	}
	diff := c.json("POST", "/api/git/diff", map[string]any{"worktree": tree, "path": "new file.txt"}, http.StatusOK)
	if !strings.Contains(diff["content"].(string), "+new") {
		t.Fatal(diff)
	}
	c.json("POST", "/api/git/status", map[string]any{"worktree": t.TempDir()}, http.StatusForbidden)
	c.json("POST", "/api/git/diff", map[string]any{"worktree": tree, "path": "../private"}, http.StatusBadRequest)
}

func TestParseGitStatus(t *testing.T) {
	entries := parseGitStatus("R  new name\x00old name\x00 M line\nbreak\x00?? fresh\x00")
	if len(entries) != 3 || entries[0].OriginalPath != "old name" || entries[1].Path != "line\nbreak" {
		t.Fatalf("unexpected entries: %+v", entries)
	}
}
