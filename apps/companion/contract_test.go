package main

import (
	"context"
	"encoding/json"
	"os"
	"testing"
)

func TestSharedSnapshotContract(t *testing.T) {
	fixture, err := os.ReadFile("../../tests/fixtures/companion-snapshot.json")
	if err != nil {
		t.Fatal(err)
	}
	s := newState(hostFunc(func(_ context.Context, method string, _ any) (hostResponse, error) {
		if method != "snapshot" {
			t.Fatalf("unexpected method %q", method)
		}
		return hostResponse{Result: fixture}, nil
	}), "http://localhost:8765")
	snapshot := s.refresh(context.Background())
	var original map[string]json.RawMessage
	if err := json.Unmarshal(fixture, &original); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"sessions", "inbox", "workspaces", "worktrees", "epoch"} {
		var want, got any
		if err := json.Unmarshal(original[field], &want); err != nil {
			t.Fatal(err)
		}
		if err := json.Unmarshal(snapshot[field], &got); err != nil {
			t.Fatal(err)
		}
		wantJSON, _ := json.Marshal(want)
		gotJSON, _ := json.Marshal(got)
		if string(wantJSON) != string(gotJSON) {
			t.Fatalf("bridge changed %s", field)
		}
	}
	if string(snapshot["connected"]) != "true" {
		t.Fatal("fixture did not connect")
	}
	if string(snapshot["cursor"]) == string(original["cursor"]) {
		t.Fatal("bridge must own its cursor")
	}
}
