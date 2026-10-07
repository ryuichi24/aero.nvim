package main

import (
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
)

const maxRecordingSize = 256 * 1024 * 1024

func (b *bridge) video(w http.ResponseWriter, r *http.Request) {
	rootName, relative, ok := b.mediaLocation(w, r)
	if !ok {
		return
	}
	if b.recordingsDir == "" {
		reject(w, 503, "recording storage unavailable")
		return
	}
	key := sha256.Sum256([]byte(b.state.origin + "\x00" + r.URL.Query().Get("session") + "\x00" + filepath.Join(rootName, relative)))
	name := fmt.Sprintf("%x", key)
	if err := os.MkdirAll(b.recordingsDir, 0700); err != nil {
		reject(w, 503, "recording storage unavailable")
		return
	}
	archive, err := os.OpenRoot(b.recordingsDir)
	if err != nil {
		reject(w, 503, "recording storage unavailable")
		return
	}
	defer archive.Close()
	file, err := archive.Open(name)
	if os.IsNotExist(err) {
		root, openErr := os.OpenRoot(rootName)
		if openErr != nil {
			reject(w, 404, "recording file unavailable")
			return
		}
		defer root.Close()
		source, openErr := root.Open(relative)
		if openErr != nil {
			reject(w, 404, "recording file unavailable")
			return
		}
		defer source.Close()
		info, statErr := source.Stat()
		if statErr != nil || !info.Mode().IsRegular() || info.Size() == 0 || info.Size() > maxRecordingSize {
			reject(w, 400, "recording must be a finalized regular file under 256 MiB")
			return
		}
		header := make([]byte, 512)
		n, _ := source.Read(header)
		media := http.DetectContentType(header[:n])
		if media != "video/webm" && media != "video/mp4" {
			reject(w, 400, "unsupported recording format; use WebM or MP4")
			return
		}
		_, _ = source.Seek(0, io.SeekStart)
		// Publish only complete copies. Concurrent viewers can safely race to
		// archive the same finalized recording without serving partial files.
		temporary := name + "." + randomToken(12)
		copy, copyErr := archive.OpenFile(temporary, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
		if copyErr != nil {
			reject(w, 503, "could not preserve recording")
			return
		}
		defer archive.Remove(temporary)
		written, copyErr := io.Copy(copy, io.LimitReader(source, maxRecordingSize+1))
		closeErr := copy.Close()
		if copyErr != nil || closeErr != nil || written != info.Size() || written > maxRecordingSize {
			reject(w, 503, "recording changed while saving; finish recording before sharing")
			return
		}
		if err := os.Rename(filepath.Join(b.recordingsDir, temporary), filepath.Join(b.recordingsDir, name)); err != nil {
			reject(w, 503, "could not preserve recording")
			return
		}
		file, err = archive.Open(name)
	}
	if err != nil {
		reject(w, 503, "saved recording unavailable")
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		reject(w, 404, "saved recording unavailable")
		return
	}
	header := make([]byte, 512)
	n, _ := file.Read(header)
	w.Header().Set("Content-Type", http.DetectContentType(header[:n]))
	_, _ = file.Seek(0, io.SeekStart)
	// ServeContent supports byte-range requests for seeking without loading
	// the entire recording into memory.
	http.ServeContent(w, r, filepath.Base(relative), info.ModTime(), file)
}
