package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

type gitEntry struct {
	Path         string `json:"path"`
	OriginalPath string `json:"original_path,omitempty"`
	Index        string `json:"index"`
	Worktree     string `json:"worktree"`
}

type gitOutput struct{ bytes.Buffer }

func (b *gitOutput) Write(p []byte) (int, error) {
	if b.Len()+len(p) > maxSourceSize {
		return 0, errors.New("Git output exceeds the 2 MiB reading limit")
	}
	return b.Buffer.Write(p)
}

func runGit(ctx context.Context, tree string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"--no-pager", "--literal-pathspecs", "-C", tree}, args...)...)
	var output gitOutput
	cmd.Stdout = &output
	cmd.Stderr = io.Discard
	err := cmd.Run()
	return output.String(), err
}

func parseGitStatus(raw string) []gitEntry {
	entries := []gitEntry{}
	parts := strings.Split(raw, "\x00")
	for i := 0; i < len(parts); i++ {
		part := parts[i]
		if len(part) < 4 {
			continue
		}
		entry := gitEntry{Path: part[3:], Index: part[:1], Worktree: part[1:2]}
		if strings.ContainsAny(part[:2], "RC") && i+1 < len(parts) {
			i++
			entry.OriginalPath = parts[i]
		}
		entries = append(entries, entry)
	}
	return entries
}

func (b *bridge) git(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Worktree string `json:"worktree"`
		Path     string `json:"path"`
		Staged   bool   `json:"staged"`
	}
	if !decodeBody(w, r, &input) {
		return
	}
	snapshot := b.state.refresh(r.Context())
	if string(snapshot["connected"]) != "true" {
		reject(w, http.StatusServiceUnavailable, "Neovim unavailable")
		return
	}
	var trees []struct {
		Path string `json:"path"`
	}
	_ = json.Unmarshal(snapshot["worktrees"], &trees)
	allowed := false
	for _, tree := range trees {
		if tree.Path == input.Worktree {
			allowed = true
			break
		}
	}
	if !allowed {
		reject(w, http.StatusForbidden, "worktree unavailable")
		return
	}
	raw, err := runGit(r.Context(), input.Worktree, "status", "--porcelain=v1", "-z", "--untracked-files=all")
	if err != nil {
		reject(w, http.StatusBadRequest, "Git status unavailable (repository missing or output too large)")
		return
	}
	entries := parseGitStatus(raw)
	if r.URL.Path == "/api/git/status" {
		reply(w, http.StatusOK, map[string]any{"entries": entries})
		return
	}
	if !filepath.IsLocal(input.Path) {
		reject(w, http.StatusBadRequest, "invalid Git path")
		return
	}
	var selected *gitEntry
	for i := range entries {
		if entries[i].Path == input.Path {
			selected = &entries[i]
			break
		}
	}
	if selected == nil {
		reject(w, http.StatusNotFound, "file no longer has changes; refresh Git status")
		return
	}
	var diff string
	if selected.Index == "?" && !input.Staged {
		root, openErr := os.OpenRoot(input.Worktree)
		if openErr != nil {
			reject(w, http.StatusNotFound, "worktree unavailable")
			return
		}
		defer root.Close()
		file, openErr := root.Open(input.Path)
		if openErr != nil {
			reject(w, http.StatusBadRequest, "untracked file unavailable")
			return
		}
		defer file.Close()
		info, statErr := file.Stat()
		if statErr != nil || !info.Mode().IsRegular() {
			reject(w, http.StatusBadRequest, "not a regular file")
			return
		}
		data, readErr := io.ReadAll(io.LimitReader(file, maxSourceSize+1))
		if readErr != nil || len(data) > maxSourceSize {
			reject(w, http.StatusBadRequest, "file exceeds the 2 MiB reading limit")
			return
		}
		if !utf8.Valid(data) || bytes.Contains(data, []byte{0}) {
			diff = "Binary file (untracked)\n"
		} else if len(data) > 0 {
			lines := strings.Split(strings.TrimSuffix(string(data), "\n"), "\n")
			diff = fmt.Sprintf("--- /dev/null\n+++ b/%s\n@@ -0,0 +1,%d @@\n+%s\n", input.Path, len(lines), strings.Join(lines, "\n+"))
			if data[len(data)-1] != '\n' {
				diff += "\\ No newline at end of file\n"
			}
		}
	} else {
		args := []string{"diff", "--no-ext-diff", "--no-textconv", "--no-color"}
		if input.Staged {
			args = append(args, "--cached")
		}
		args = append(args, "--", input.Path)
		if selected.OriginalPath != "" {
			args = append(args, selected.OriginalPath)
		}
		diff, err = runGit(r.Context(), input.Worktree, args...)
		if err != nil {
			reject(w, http.StatusBadRequest, "Git diff unavailable or exceeds the 2 MiB reading limit")
			return
		}
	}
	reply(w, http.StatusOK, map[string]string{"content": diff})
}
