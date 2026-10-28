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

	if err := os.WriteFile(filepath.Join(root, "main.go"), []byte("package main\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(filepath.Join(root, "binary"), []byte{0, 1}, 0o600); err != nil {
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
		if err := os.WriteFile(filepath.Join(reports, name), []byte(body), 0o600); err != nil {
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

func TestReferenceBrowsing(t *testing.T) {
	worktree, root, outside := t.TempDir(), t.TempDir(), t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "folder"), 0o700); err != nil {
		t.Fatal(err)
	}

	if err := os.WriteFile(filepath.Join(root, "folder", "reference.txt"), []byte("reference"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := os.Symlink(outside, filepath.Join(root, "escape")); err != nil {
		t.Fatal(err)
	}

	data, _ := json.Marshal(map[string]any{"sessions": []any{}, "worktrees": []any{map[string]string{"path": worktree, "reference_directory": root}}})
	c := newClient(t, hostFunc(func(context.Context, string, any) (hostResponse, error) { return hostResponse{Result: data}, nil }))
	request := func(path string, status int) map[string]any {
		return c.json("POST", "/api/reference", map[string]string{"worktree": worktree, "path": path}, status)
	}
	request("", http.StatusUnauthorized)
	c.pair()

	listing := request("", http.StatusOK)

	entries := listing["entries"].([]any)
	if len(entries) != 1 || entries[0].(map[string]any)["name"] != "folder" {
		t.Fatalf("unexpected references: %v", listing)
	}

	request("folder", http.StatusOK)

	if request("folder/reference.txt", http.StatusOK)["content"] != "reference" {
		t.Fatal("reference content missing")
	}

	request("../", http.StatusBadRequest)
	request("escape", http.StatusNotFound)
	c.json("POST", "/api/reference", map[string]string{"worktree": outside}, http.StatusForbidden)
}

func TestReferenceActionsForwardWorktreeScope(t *testing.T) {
	c := newClient(t, hostFunc(func(_ context.Context, method string, params any) (hostResponse, error) {
		encoded, _ := json.Marshal(params)

		var input map[string]any

		_ = json.Unmarshal(encoded, &input)
		if input["worktree"] != "/repo" || input["target"] != "target" || input["epoch"] != "epoch" {
			t.Fatalf("lost scope: %s", encoded)
		}

		if method == "reference_browse" {
			return hostResponse{Result: json.RawMessage(`{"path":"/home","entries":[]}`)}, nil
		}

		if method == "reference_cancel" && input["transfer_id"] == "reference-operation-0001" {
			return hostResponse{Result: json.RawMessage(`{"status":"accepted"}`)}, nil
		}

		if method != "reference_update" || input["reference_action"] != "transfer" || len(input["items"].([]any)) != 1 {
			t.Fatalf("unexpected reference action: %s %s", method, encoded)
		}

		return hostResponse{Result: json.RawMessage(`{"status":"accepted"}`)}, nil
	}))
	c.json("POST", "/api/reference_cancel", map[string]any{}, http.StatusUnauthorized)
	c.pair()
	c.json("POST", "/api/reference_browse", map[string]any{"epoch": "epoch", "target": "target", "worktree": "/repo", "path": ""}, http.StatusOK)
	c.json("POST", "/api/reference_update", map[string]any{"operation_id": "reference-operation-0001", "epoch": "epoch", "target": "target", "worktree": "/repo", "reference_action": "transfer", "items": []map[string]string{{"path": "/home/ref", "action": "copy"}}}, http.StatusOK)
	c.json("POST", "/api/reference_cancel", map[string]any{"operation_id": "reference-cancellation-0001", "epoch": "epoch", "target": "target", "worktree": "/repo", "transfer_id": "reference-operation-0001"}, http.StatusOK)
}

func TestSubmoduleDiscoveryForwardsCheckoutScope(t *testing.T) {
	c := newClient(t, hostFunc(func(_ context.Context, method string, params any) (hostResponse, error) {
		encoded, _ := json.Marshal(params)

		var input map[string]any

		_ = json.Unmarshal(encoded, &input)
		if method != "submodule_browse" || input["worktree"] != "/parent" || input["path"] != "/parent/libs/core" || input["epoch"] != "epoch" || input["target"] != "target" || input["refresh"] != true {
			t.Fatalf("lost submodule scope: %s %s", method, encoded)
		}

		return hostResponse{Result: json.RawMessage(`{"entries":[],"loading":false,"workspace":"/parent/libs/core","worktrees":[{"path":"/external/core"}]}`)}, nil
	}))
	c.json("POST", "/api/submodule_browse", map[string]any{}, http.StatusUnauthorized)
	c.pair()
	c.json("POST", "/api/submodule_browse", map[string]any{"epoch": "epoch", "target": "target", "worktree": "/parent", "path": "/parent/libs/core", "refresh": true}, http.StatusOK)
}

func TestReferenceTransferPollsIdenticalReceipt(t *testing.T) {
	calls := 0

	var previous string

	c := newClient(t, hostFunc(func(_ context.Context, method string, params any) (hostResponse, error) {
		encoded, _ := json.Marshal(params)
		if method != "reference_update" || (previous != "" && previous != string(encoded)) {
			t.Fatalf("poll changed action: %s %s", method, encoded)
		}

		previous = string(encoded)

		calls++
		if calls < 3 {
			return hostResponse{Result: json.RawMessage(`{"status":"unknown"}`)}, nil
		}

		return hostResponse{Result: json.RawMessage(`{"status":"accepted"}`)}, nil
	}))
	c.pair()

	result := c.json("POST", "/api/reference_update", map[string]any{"operation_id": "reference-operation-0001", "reference_action": "transfer"}, http.StatusOK)
	if calls != 3 || result["result"].(map[string]any)["status"] != "accepted" {
		t.Fatalf("transfer receipt not polled: %v", result)
	}
}
