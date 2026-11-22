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
	root, outside, reports := t.TempDir(), t.TempDir(), t.TempDir()
	png := []byte("\x89PNG\r\n\x1a\nimage fixture")

	external := filepath.Join(outside, "shot.png")
	for _, name := range []string{filepath.Join(root, "shot.png"), external, filepath.Join(reports, "report.png")} {
		if err := os.WriteFile(name, png, 0o600); err != nil {
			t.Fatal(err)
		}
	}

	if err := os.Symlink(external, filepath.Join(root, "escape.png")); err != nil {
		t.Fatal(err)
	}

	data, _ := json.Marshal(map[string]any{"worktrees": []any{map[string]string{"path": root, "reports_directory": reports}}, "sessions": []any{map[string]any{"id": "one", "worktree": root, "blocks": []any{map[string]string{"text": "[Screenshot](" + external + ")"}}}}})
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
	check("file://"+filepath.Join(reports, "report.png"), 200)
	check(filepath.Join(reports, "..", "unlinked.png"), 403)
	check(filepath.Join(outside, "unlinked.png"), 403)
	check("../shot.png", 403)
	check("escape.png", 404)
}

func TestLazyScreenshot(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()

	image := filepath.Join(outside, "shot.png")
	if err := os.WriteFile(image, []byte("\x89PNG\r\n\x1a\nfixture"), 0o600); err != nil {
		t.Fatal(err)
	}

	reads := 0
	c := newClient(t, hostFunc(func(_ context.Context, method string, params any) (hostResponse, error) {
		var value any

		if method == "snapshot" {
			value = map[string]any{"epoch": "epoch", "sessions": []any{map[string]any{
				"id": "saved", "worktree": root, "target": "target", "transcript_lazy": true,
			}}}
		} else if method == "session_snapshot" {
			reads++

			input := params.(map[string]string)
			if input["session"] != "saved" || input["target"] != "target" || input["epoch"] != "epoch" {
				t.Error("media read lost session scope")
			}

			value = map[string]any{"session": map[string]any{"blocks": []any{map[string]string{"text": "[Screenshot](" + image + ")"}}}}
		} else {
			t.Errorf("unexpected host method %s", method)
		}

		data, err := json.Marshal(value)

		return hostResponse{Result: data}, err
	}))
	c.pair()

	response := c.request("GET", "/api/image?"+url.Values{"session": {"saved"}, "path": {image}}.Encode(), nil, "")
	defer response.Body.Close()

	if response.StatusCode != 200 || reads != 1 {
		t.Fatalf("lazy media status=%d, transcript reads=%d", response.StatusCode, reads)
	}
}
