package main

import (
	"context"
	"encoding/json"
	"sync"
	"sync/atomic"
	"testing"
	"time"
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

func TestCachedSnapshotSharesRefreshAndInvalidates(t *testing.T) {
	var calls atomic.Int32
	s := newState(hostFunc(func(context.Context, string, any) (hostResponse, error) {
		calls.Add(1)
		return hostResponse{Result: json.RawMessage(`{"sessions":[]}`)}, nil
	}), "http://localhost:8765")
	var readers sync.WaitGroup
	for range 24 {
		readers.Add(1)
		go func() {
			defer readers.Done()
			if value := s.cachedSnapshot(context.Background(), time.Minute); string(value["connected"]) != "true" {
				t.Error("reader did not receive shared snapshot")
			}
		}()
	}
	readers.Wait()
	if calls.Load() != 1 {
		t.Fatalf("concurrent readers made %d host calls", calls.Load())
	}
	s.invalidateSnapshot()
	s.cachedSnapshot(context.Background(), time.Minute)
	if calls.Load() != 2 {
		t.Fatal("action invalidation did not refresh snapshot")
	}
}

func TestCachedSnapshotCancellationDoesNotCancelSharedRead(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	s := newState(hostFunc(func(ctx context.Context, _ string, _ any) (hostResponse, error) {
		calls.Add(1)
		close(started)
		select {
		case <-release:
			return hostResponse{Result: json.RawMessage(`{"sessions":[]}`)}, nil
		case <-ctx.Done():
			return hostResponse{}, ctx.Err()
		}
	}), "http://localhost:8765")
	ctx, cancel := context.WithCancel(context.Background())
	finished := make(chan map[string]json.RawMessage, 1)
	go func() { finished <- s.cachedSnapshot(ctx, time.Minute) }()
	<-started
	cancel()
	select {
	case value := <-finished:
		if value != nil {
			t.Fatal("canceled reader received snapshot")
		}
	case <-time.After(time.Second):
		t.Fatal("canceled reader waited for slow host")
	}
	close(release)
	value := s.cachedSnapshot(context.Background(), time.Minute)
	if string(value["connected"]) != "true" || calls.Load() != 1 {
		t.Fatal("disconnect canceled the shared refresh")
	}
}

func TestCachedSnapshotDiscardsReadInvalidatedInFlight(t *testing.T) {
	started, release := make(chan struct{}), make(chan struct{})
	var calls atomic.Int32
	s := newState(hostFunc(func(context.Context, string, any) (hostResponse, error) {
		if calls.Add(1) == 1 {
			close(started)
			<-release
			return hostResponse{Result: json.RawMessage(`{"sessions":[{"id":"old"}]}`)}, nil
		}
		return hostResponse{Result: json.RawMessage(`{"sessions":[{"id":"new"}]}`)}, nil
	}), "http://localhost:8765")
	finished := make(chan map[string]json.RawMessage, 1)
	go func() { finished <- s.cachedSnapshot(context.Background(), time.Minute) }()
	<-started
	s.invalidateSnapshot()
	close(release)
	value := <-finished
	if string(value["sessions"]) != `[{"id":"new"}]` || calls.Load() != 2 {
		t.Fatal("published snapshot from before action invalidation")
	}
}
