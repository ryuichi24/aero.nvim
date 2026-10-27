package main

// Static UI asset boundary. Build web/dist before compiling the bridge.
import (
	"embed"
	"io/fs"
	"mime"
	"net/http"
	"path"
	"strconv"
	"strings"
)

//go:embed web/dist
var bundledUI embed.FS

func (b *bridge) static(w http.ResponseWriter, r *http.Request) {
	name := strings.TrimPrefix(r.URL.Path, "/")
	if name == "" {
		name = "index.html"
	}

	if !fs.ValidPath(name) || (name != "index.html" && name != "manifest.webmanifest" && !strings.HasPrefix(name, "assets/")) {
		reject(w, http.StatusNotFound, "unknown route")
		return
	}

	data, err := fs.ReadFile(b.ui, name)
	if err != nil {
		reject(w, http.StatusNotFound, "unknown route")
		return
	}

	typeName := mime.TypeByExtension(path.Ext(name))
	if name == "manifest.webmanifest" {
		typeName = "application/manifest+json"
	}

	w.Header().Set("Content-Type", typeName)
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}
