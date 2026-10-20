package main

// SSE consumes cached snapshots; authentication is rechecked around slow host reads.
import (
	"encoding/json"
	"io"
	"net/http"
	"time"
)

func (b *bridge) events(w http.ResponseWriter, r *http.Request, token string) {
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("X-Accel-Buffering", "no")
	controller := http.NewResponseController(w)
	cursor := ""
	ticker := time.NewTicker(b.pollInterval)
	defer ticker.Stop()
	for {
		if _, ok := b.state.authenticate(token); !ok {
			return
		}
		snapshot := b.state.cachedSnapshot(r.Context(), b.pollInterval)
		if _, ok := b.state.authenticate(token); !ok || r.Context().Err() != nil {
			return
		}
		_ = controller.SetWriteDeadline(time.Now().Add(10 * time.Second))
		current := string(snapshot["cursor"])
		if current != cursor {
			cursor = current
			var id string
			_ = json.Unmarshal(snapshot["cursor"], &id)
			encoded, _ := json.Marshal(snapshot)
			if _, err := io.WriteString(w, "id: "+id+"\ndata: "+string(encoded)+"\n\n"); err != nil {
				return
			}
		} else if _, err := io.WriteString(w, "event: heartbeat\ndata: {}\n\n"); err != nil {
			return
		}
		if err := controller.Flush(); err != nil {
			return
		}
		select {
		case <-r.Context().Done():
			return
		case <-ticker.C:
		}
	}
}
