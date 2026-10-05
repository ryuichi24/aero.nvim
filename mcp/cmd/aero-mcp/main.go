package main

import (
	"bufio"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var version = "0.2.0-dev"

const protocol = 1
const maxMessage = 1024 * 1024

type client struct{ socket, credential string }

func (c client) call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", c.socket)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	request := map[string]any{"version": protocol, "id": "1", "credential": c.credential, "method": method, "params": params}
	data, err := json.Marshal(request)
	if err != nil {
		return nil, err
	}
	if len(data)+1 > maxMessage {
		return nil, fmt.Errorf("request exceeds message limit")
	}
	if _, err = conn.Write(append(data, '\n')); err != nil {
		return nil, err
	}
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), maxMessage)
	if !scanner.Scan() {
		if err := scanner.Err(); err != nil {
			return nil, err
		}
		return nil, io.ErrUnexpectedEOF
	}
	var response struct {
		Version int             `json:"version"`
		ID      string          `json:"id"`
		Result  json.RawMessage `json:"result"`
		Error   json.RawMessage `json:"error"`
	}
	if err := json.Unmarshal(scanner.Bytes(), &response); err != nil {
		return nil, err
	}
	if response.Version != protocol || response.ID != "1" {
		return nil, fmt.Errorf("incompatible bridge response")
	}
	if len(response.Error) != 0 && string(response.Error) != "null" {
		return nil, fmt.Errorf("%s", response.Error)
	}
	return response.Result, nil
}

type readArgs struct{}
type reportArgs struct {
	OperationID string `json:"operation_id" jsonschema:"Unique retry identifier; reuse only for identical arguments"`
	Name        string `json:"name" jsonschema:"Report filename without directory separators; .md is appended if omitted"`
	Body        string `json:"body" jsonschema:"Complete Markdown report with findings"`
}
type createArgs struct {
	OperationID           string `json:"operation_id" jsonschema:"Unique retry identifier; reuse only for identical arguments"`
	ExpectedBoardRevision string `json:"expected_board_revision"`
	Title                 string `json:"title" jsonschema:"Nonempty single-line ticket title"`
	TaskType              string `json:"task_type,omitempty" jsonschema:"general, implementation, or report; defaults to general"`
	TargetState           string `json:"target_state" jsonschema:"Existing state on the assigned board"`
	Body                  string `json:"body" jsonschema:"Initial Markdown content below the generated ticket title"`
}
type moveArgs struct {
	OperationID           string `json:"operation_id" jsonschema:"Unique retry identifier; reuse only for identical arguments"`
	TargetState           string `json:"target_state"`
	ExpectedState         string `json:"expected_state"`
	ExpectedBoardRevision string `json:"expected_board_revision"`
	Position              *int   `json:"position,omitempty"`
}
type bodyArgs struct {
	OperationID            string `json:"operation_id"`
	ExpectedTicketRevision string `json:"expected_ticket_revision"`
	Body                   string `json:"body"`
}
type metadataArgs struct {
	OperationID            string         `json:"operation_id"`
	ExpectedTicketRevision string         `json:"expected_ticket_revision"`
	Changes                map[string]any `json:"changes" jsonschema:"Only task_type priority tags assignees due_date and estimate; task_type is general implementation or report"`
}

func addTool[T any](server *mcp.Server, c client, method, description string) {
	mcp.AddTool(server, &mcp.Tool{Name: "aero_" + method, Description: description},
		func(ctx context.Context, _ *mcp.CallToolRequest, args T) (*mcp.CallToolResult, any, error) {
			data, err := c.call(ctx, method, args)
			if err != nil {
				return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: err.Error()}}}, nil, nil
			}
			return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: string(data)}}}, nil, nil
		})
}

func run() error {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"version": version, "bridge_protocol": protocol})
	}
	if len(os.Args) < 2 {
		return fmt.Errorf("usage: aero-mcp serve|call --socket PATH [METHOD JSON]")
	}
	flags := flag.NewFlagSet(os.Args[1], flag.ContinueOnError)
	socket := flags.String("socket", os.Getenv("AERO_TASK_SOCKET"), "Aero instance socket")
	if err := flags.Parse(os.Args[2:]); err != nil {
		return err
	}
	c := client{socket: *socket, credential: os.Getenv("AERO_TASK_CREDENTIAL")}
	if c.socket == "" || c.credential == "" {
		return fmt.Errorf("socket and AERO_TASK_CREDENTIAL are required")
	}
	switch os.Args[1] {
	case "call":
		args := flags.Args()
		if len(args) < 1 || len(args) > 2 {
			return fmt.Errorf("call requires METHOD and optional JSON arguments")
		}
		params := json.RawMessage(`{}`)
		if len(args) == 2 {
			params = json.RawMessage(args[1])
			if !json.Valid(params) {
				return fmt.Errorf("invalid JSON arguments")
			}
		}
		data, err := c.call(context.Background(), args[0], params)
		if err != nil {
			return err
		}
		_, err = fmt.Fprintln(os.Stdout, string(data))
		return err
	case "serve":
		server := mcp.NewServer(&mcp.Implementation{Name: "aero-mcp", Version: version}, nil)
		addTool[readArgs](server, c, "list_boards", "List committed board summaries in the assigned workspace")
		addTool[readArgs](server, c, "get_board", "Read assigned board states, placements, revision and draft indicators")
		addTool[readArgs](server, c, "get_ticket", "Read assigned committed ticket and revisions before making changes")
		addTool[reportArgs](server, c, "create_report", "Create a new Markdown findings report in the assigned execution worktree's configured report directory; never overwrites existing reports")
		addTool[createArgs](server, c, "create_ticket", "Create a ticket with initial Markdown content on the assigned board; read the board revision first")
		addTool[moveArgs](server, c, "move_ticket", "Conditionally move assigned ticket; never changes progress automatically")
		addTool[bodyArgs](server, c, "update_ticket_body", "Replace ticket Markdown body while preserving frontmatter and drafts")
		addTool[metadataArgs](server, c, "update_ticket_metadata", "Conditionally update non-title ticket metadata")
		return server.Run(context.Background(), &mcp.StdioTransport{})
	default:
		return fmt.Errorf("unknown command %q", os.Args[1])
	}
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
