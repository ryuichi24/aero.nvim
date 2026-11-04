package main

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestBrowserToolResults(t *testing.T) {
	for _, tc := range []struct {
		name     string
		response string
		isError  bool
	}{
		{"dependency", `{"error":{"code":"dependency_missing","message":"Not installed","suggested_command":"brew install terminal-browser","installation_url":"https://github.com/zenbu-labs/terminal-browser#installation"}}`, true},
		{"screenshot", `{"result":{"page_id":"browser:1","action":"screenshot","image":{"mime_type":"image/png","data":"aW1hZ2U="}}}`, false},
		{"fill", `{"result":{"page_id":"browser:1","action":"fill"}}`, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			dir, err := os.MkdirTemp("", "ab-")
			if err != nil {
				t.Fatal(err)
			}
			defer os.RemoveAll(dir)

			socket := filepath.Join(dir, "s")

			listener, err := net.Listen("unix", socket)
			if err != nil {
				t.Fatal(err)
			}
			defer listener.Close()

			go func() {
				conn, err := listener.Accept()
				if err != nil {
					return
				}
				defer conn.Close()

				var request map[string]any
				if err := json.NewDecoder(conn).Decode(&request); err != nil {
					t.Error(err)
					return
				}

				if request["credential"] != "browser-binding" || request["method"] != "browser_action" {
					t.Errorf("unexpected request: %v", request)
				}

				if tc.name == "fill" {
					params, _ := request["params"].(map[string]any)
					if text, exists := params["text"]; !exists || text != "" {
						t.Errorf("empty fill text was not preserved: %v", params)
					}
				}

				var response map[string]any
				if err := json.Unmarshal([]byte(tc.response), &response); err != nil {
					t.Error(err)
					return
				}

				response["id"], response["version"] = "1", 1
				_ = json.NewEncoder(conn).Encode(response)
			}()

			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()

			server := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "1"}, nil)
			registerBrowserTools(server, client{socket: socket, credential: "browser-binding"})

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

			args := map[string]any{"page_id": "browser:1", "action": "screenshot"}

			if tc.name == "fill" {
				args["action"], args["ref"], args["text"] = "fill", "@e1", ""
			}

			result, err := cs.CallTool(ctx, &mcp.CallToolParams{Name: "aero_browser_action", Arguments: args})
			if err != nil {
				t.Fatal(err)
			}

			if result.IsError != tc.isError {
				t.Fatalf("IsError = %v", result.IsError)
			}

			structured, _ := json.Marshal(result.StructuredContent)

			if tc.isError {
				if !strings.Contains(string(structured), `"code":"dependency_missing"`) || !strings.Contains(string(structured), "brew install") {
					t.Fatalf("missing structured guidance: %s", structured)
				}
			} else if tc.name == "screenshot" {
				image, ok := result.Content[0].(*mcp.ImageContent)
				if !ok || image.MIMEType != "image/png" || string(image.Data) != "image" {
					t.Fatalf("missing image content: %#v", result.Content)
				}

				if strings.Contains(string(structured), `"image"`) {
					t.Fatalf("image duplicated in structured text: %s", structured)
				}
			}
		})
	}
}
