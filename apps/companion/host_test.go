package main

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"path/filepath"
	"strings"
	"testing"
)

func TestLargeSnapshot(t *testing.T) {
	path := filepath.Join(t.TempDir(), "host.sock")

	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}

	t.Cleanup(func() { _ = listener.Close() })

	answer := strings.Repeat("x", 17*1024*1024)
	done := make(chan error, 1)

	go func() {
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			done <- acceptErr
			return
		}
		defer conn.Close()

		if _, readErr := bufio.NewReader(conn).ReadBytes('\n'); readErr != nil {
			done <- readErr
			return
		}

		done <- json.NewEncoder(conn).Encode(map[string]any{
			"result": map[string]any{"sessions": []any{map[string]any{"text": answer}}},
		})
	}()

	response, err := (unixHost{path: path}).Call(context.Background(), "snapshot", nil)
	if err != nil {
		t.Fatal(err)
	}

	if err = <-done; err != nil {
		t.Fatal(err)
	}

	var snapshot struct {
		Sessions []struct{ Text string }
	}
	if err = json.Unmarshal(response.Result, &snapshot); err != nil {
		t.Fatal(err)
	}

	if len(snapshot.Sessions) != 1 || snapshot.Sessions[0].Text != answer {
		t.Fatal("saved transcript was truncated")
	}
}
