package main

import (
	"context"
	"encoding/json"
	"testing"
)

func TestSnapshotCursorIgnoresObjectKeyOrder(t *testing.T) {
	values := []string{
		`{"sessions":[{"id":"one","metrics":{"tokens":9007199254740993,"cost":0.125}}],"worktrees":[]}`,
		`{"worktrees":[],"sessions":[{"metrics":{"cost":0.125,"tokens":9007199254740993},"id":"one"}]}`,
		`{"sessions":[{"id":"one","metrics":{"tokens":9007199254740994,"cost":0.125}}],"worktrees":[]}`,
	}
	index := 0
	s := newState(hostFunc(func(context.Context, string, any) (hostResponse, error) {
		value := values[index]
		index++
		return hostResponse{Result: json.RawMessage(value)}, nil
	}), "http://localhost:8765")
	first := s.refresh(context.Background())
	second := s.refresh(context.Background())
	third := s.refresh(context.Background())
	if string(first["cursor"]) != string(second["cursor"]) {
		t.Fatal("equivalent snapshots changed cursor after object key reordering")
	}
	if string(second["cursor"]) == string(third["cursor"]) {
		t.Fatal("changed snapshot did not advance cursor")
	}
}
