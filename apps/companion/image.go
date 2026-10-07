package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

// Images are read only for an active session. Outside its worktree, the exact
// file must have been linked in that session's transcript (e.g. Playwright output).
func (b *bridge) image(w http.ResponseWriter, r *http.Request) {
	rootName, relative, ok := b.mediaLocation(w, r)
	if !ok {
		return
	}
	root, err := os.OpenRoot(rootName)
	if err != nil {
		reject(w, 404, "image unavailable")
		return
	}
	defer root.Close()
	file, err := root.Open(relative)
	if err != nil {
		reject(w, 404, "image unavailable")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > 20*1024*1024 {
		reject(w, 400, "image must be a regular file under 20 MiB")
		return
	}
	data, err := io.ReadAll(io.LimitReader(file, 20*1024*1024+1))
	if err != nil || len(data) > 20*1024*1024 {
		reject(w, 400, "image unavailable")
		return
	}
	media := http.DetectContentType(data)
	if media != "image/png" && media != "image/jpeg" && media != "image/webp" && media != "image/gif" {
		reject(w, 400, "unsupported image format")
		return
	}
	w.Header().Set("Content-Type", media)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func (b *bridge) mediaLocation(w http.ResponseWriter, r *http.Request) (string, string, bool) {
	snapshot := b.state.refresh(r.Context())
	if string(snapshot["connected"]) != "true" {
		reject(w, http.StatusServiceUnavailable, "Neovim unavailable")
		return "", "", false
	}
	var sessions []struct {
		ID       string `json:"id"`
		Worktree string `json:"worktree"`
		Blocks   any    `json:"blocks"`
	}
	_ = json.Unmarshal(snapshot["sessions"], &sessions)
	name := r.URL.Query().Get("path")
	if strings.HasPrefix(name, "file://") {
		u, err := url.Parse(name)
		if err != nil || (u.Host != "" && u.Host != "localhost") {
			reject(w, 400, "invalid media path")
			return "", "", false
		}
		name = u.Path
	}
	var rootName, relative string
	for _, session := range sessions {
		if session.ID != r.URL.Query().Get("session") {
			continue
		}
		rootName, relative = session.Worktree, name
		if filepath.IsAbs(name) {
			relative, _ = filepath.Rel(rootName, name)
			if !filepath.IsLocal(relative) && imageReferenced(session.Blocks, name) {
				rootName, relative = filepath.Dir(name), filepath.Base(name)
			}
		}
		break
	}
	if rootName == "" || !filepath.IsLocal(relative) {
		reject(w, 403, "media unavailable for this session")
		return "", "", false
	}
	return rootName, relative, true
}

func imageReferenced(value any, name string) bool {
	switch value := value.(type) {
	case string:
		return value == name || value == "file://"+name || strings.Contains(value, "("+name+")") || strings.Contains(value, "(file://"+name+")")
	case []any:
		for _, item := range value {
			if imageReferenced(item, name) {
				return true
			}
		}
	case map[string]any:
		for _, item := range value {
			if imageReferenced(item, name) {
				return true
			}
		}
	}
	return false
}
