package main

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"path/filepath"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestMCPDiscoveryAndScopedCall(t *testing.T) {
	path := filepath.Join(t.TempDir(), "task.sock")
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	requests := make(chan map[string]any, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var request map[string]any
		if json.NewDecoder(bufio.NewReader(conn)).Decode(&request) != nil {
			return
		}
		requests <- request
		_ = json.NewEncoder(conn).Encode(map[string]any{"version": 1, "id": "1", "result": map[string]any{"ticket_id": "assigned", "committed": true}})
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	server := mcp.NewServer(&mcp.Implementation{Name: "fixture", Version: version}, nil)
	c := client{socket: path, credential: "private-binding"}
	addTool[readArgs](server, c, "get_ticket", "Committed ticket")
	addTool[moveArgs](server, c, "move_ticket", "Conditional movement")
	st, ct := mcp.NewInMemoryTransports()
	ss, err := server.Connect(ctx, st, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ss.Close()
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "test", Version: "1"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	tools, err := cs.ListTools(ctx, nil)
	if err != nil || len(tools.Tools) != 2 {
		t.Fatalf("discovery: %v %+v", err, tools)
	}
	result, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "aero_get_ticket", Arguments: map[string]any{}})
	if err != nil || result.IsError {
		t.Fatalf("call: %v %+v", err, result)
	}
	request := <-requests
	if request["credential"] != "private-binding" || request["method"] != "get_ticket" || request["version"] != float64(1) {
		t.Fatalf("bad bridge request: %+v", request)
	}
	if len(result.Content) != 1 {
		t.Fatalf("missing result: %+v", result)
	}
}

func TestConnectionFailureIsToolError(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	server := mcp.NewServer(&mcp.Implementation{Name: "fixture", Version: version}, nil)
	addTool[readArgs](server, client{socket: filepath.Join(t.TempDir(), "absent.sock")}, "get_ticket", "Read")
	st, ct := mcp.NewInMemoryTransports()
	ss, err := server.Connect(ctx, st, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ss.Close()
	cs, err := mcp.NewClient(&mcp.Implementation{Name: "test", Version: "1"}, nil).Connect(ctx, ct, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer cs.Close()
	result, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "aero_get_ticket", Arguments: map[string]any{}})
	if err != nil || !result.IsError {
		t.Fatalf("transport failure must be tool error: %v %+v", err, result)
	}
}
