package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unicode/utf8"
)

const maxSourceSize = 2 * 1024 * 1024

type sourceEntry struct {
	Name      string `json:"name"`
	Directory bool   `json:"directory"`
}

func (b *bridge) source(w http.ResponseWriter, r *http.Request) {
	var input struct {
		Worktree string `json:"worktree"`
		Path     string `json:"path"`
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
		Path             string `json:"path"`
		ReportsDirectory string `json:"reports_directory"`
	}
	_ = json.Unmarshal(snapshot["worktrees"], &trees)
	allowed := false
	reports := r.URL.Path == "/api/reports"
	directory := input.Worktree
	for _, tree := range trees {
		if tree.Path == input.Worktree {
			allowed = true
			if reports {
				directory = tree.ReportsDirectory
			}
			break
		}
	}
	if !allowed {
		reject(w, http.StatusForbidden, "worktree unavailable")
		return
	}
	name := input.Path
	if name == "" {
		name = "."
	}
	if !filepath.IsLocal(name) {
		reject(w, http.StatusBadRequest, "invalid source path")
		return
	}
	if reports && (directory == "" || (name != "." && (filepath.Base(name) != name || !strings.HasSuffix(name, ".md")))) {
		reject(w, http.StatusBadRequest, "invalid report path")
		return
	}
	root, err := os.OpenRoot(directory)
	if err != nil {
		if reports && name == "." && os.IsNotExist(err) {
			reply(w, http.StatusOK, map[string]any{"entries": []sourceEntry{}})
			return
		}
		reject(w, http.StatusNotFound, "worktree unavailable")
		return
	}
	defer root.Close()
	stat, err := root.Stat(name)
	if err != nil {
		reject(w, http.StatusNotFound, "source path unavailable")
		return
	}
	if !stat.IsDir() && !stat.Mode().IsRegular() {
		reject(w, http.StatusBadRequest, "not a regular source file")
		return
	}
	file, err := root.Open(name)
	if err != nil {
		reject(w, http.StatusNotFound, "source path unavailable")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		reject(w, http.StatusNotFound, "source path unavailable")
		return
	}
	if info.IsDir() {
		items, err := file.ReadDir(-1)
		if err != nil {
			reject(w, http.StatusNotFound, "directory unavailable")
			return
		}
		entries := make([]sourceEntry, 0, len(items))
		for _, item := range items {
			if reports && (!item.Type().IsRegular() || !strings.HasSuffix(item.Name(), ".md")) {
				continue
			}
			if item.Name() == ".git" {
				continue
			}
			stat, err := root.Stat(filepath.Join(name, item.Name()))
			if err != nil || (!stat.IsDir() && !stat.Mode().IsRegular()) {
				continue
			}
			entries = append(entries, sourceEntry{item.Name(), stat.IsDir()})
		}
		sort.Slice(entries, func(i, j int) bool {
			if entries[i].Directory != entries[j].Directory {
				return entries[i].Directory
			}
			return entries[i].Name < entries[j].Name
		})
		reply(w, http.StatusOK, map[string]any{"entries": entries})
		return
	}
	if !info.Mode().IsRegular() {
		reject(w, http.StatusBadRequest, "not a regular source file")
		return
	}
	data, err := io.ReadAll(io.LimitReader(file, maxSourceSize+1))
	if err != nil {
		reject(w, http.StatusNotFound, "file unavailable")
		return
	}
	if len(data) > maxSourceSize {
		reject(w, http.StatusBadRequest, "file exceeds the 2 MiB reading limit")
		return
	}
	if !utf8.Valid(data) || bytes.IndexByte(data, 0) >= 0 {
		reject(w, http.StatusBadRequest, "binary files cannot be displayed")
		return
	}
	reply(w, http.StatusOK, map[string]string{"content": string(data)})
}
