package main

// Coalesced immutable snapshots and stable cursors, independent of pairing state.
import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"time"
)

// cachedSnapshot coalesces host reads. Cancellation stops only the caller's wait.
func (s *state) cachedSnapshot(ctx context.Context, maxAge time.Duration) map[string]json.RawMessage {
	for {
		if ctx.Err() != nil {
			return nil
		}

		s.snapshotMu.Lock()
		if s.snapshot != nil && time.Since(s.snapshotAt) < maxAge {
			value := s.snapshot
			s.snapshotMu.Unlock()

			return value
		}

		if s.snapshotPending == nil {
			done := make(chan struct{})
			s.snapshotPending = done
			generation := s.snapshotGeneration

			go func() {
				refreshCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
				defer cancel()

				value := s.refresh(refreshCtx)
				s.snapshotMu.Lock()
				if generation == s.snapshotGeneration {
					s.snapshot = value
					s.snapshotAt = time.Now()
				}

				s.snapshotPending = nil

				close(done)
				s.snapshotMu.Unlock()
			}()
		}

		done := s.snapshotPending
		s.snapshotMu.Unlock()

		select {
		case <-ctx.Done():
			return nil
		case <-done:
		}
	}
}

func (s *state) invalidateSnapshot() {
	s.snapshotMu.Lock()
	defer s.snapshotMu.Unlock()

	s.snapshotAt = time.Time{}
	s.snapshotGeneration++
}

func (s *state) refresh(ctx context.Context) map[string]json.RawMessage {
	s.refreshMu.Lock()
	defer s.refreshMu.Unlock()

	snapshot := make(map[string]json.RawMessage)

	response, err := s.host.Call(ctx, "snapshot", nil)
	if err == nil && response.Error == "" {
		err = json.Unmarshal(response.Result, &snapshot)
	}

	if err != nil || response.Error != "" || snapshot == nil || snapshot["sessions"] == nil {
		snapshot = map[string]json.RawMessage{
			"connected": json.RawMessage(`false`),
			"error":     json.RawMessage(`"Neovim unavailable; action outcomes may be unknown"`),
		}
	} else {
		snapshot["connected"] = json.RawMessage(`true`)
	}

	for _, field := range []string{"sessions", "inbox", "workspaces", "worktrees"} {
		if len(snapshot[field]) == 0 || string(snapshot[field]) == "null" {
			snapshot[field] = json.RawMessage(`[]`)
		}
	}

	encoded, _ := json.Marshal(snapshot)
	// Equivalent nested objects retain their cursor despite Lua key-order changes.
	var canonical any

	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()

	if decoder.Decode(&canonical) == nil {
		encoded, _ = json.Marshal(canonical)
	}

	digest := sha256.Sum256(encoded)
	if digest != s.digest {
		s.digest = digest
		s.revision++
	}

	snapshot["cursor"], _ = json.Marshal(fmt.Sprintf("%s:%d", s.epoch, s.revision))

	return snapshot
}
