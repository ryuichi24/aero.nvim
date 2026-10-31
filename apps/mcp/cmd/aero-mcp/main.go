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
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

var version = "0.4.0-dev"

const (
	protocol   = 1
	maxMessage = 1024 * 1024
)

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

type (
	readArgs    struct{}
	readingItem struct {
		ID      string `json:"id" jsonschema:"Stable unique step ID; preserve when updating a walkthrough"`
		Path    string `json:"path" jsonschema:"Existing source file relative to the session worktree"`
		Lnum    int    `json:"lnum" jsonschema:"One-based source line"`
		EndLnum *int   `json:"end_lnum,omitempty"`
		Label   string `json:"label" jsonschema:"Short explanation of this stop"`
		Note    string `json:"note,omitempty" jsonschema:"What to understand here and how it connects to the next stop"`
	}
)

type readingArgs struct {
	ID    string        `json:"id,omitempty" jsonschema:"Omit to create; reuse returned list ID to update while preserving read progress"`
	Title string        `json:"title"`
	Items []readingItem `json:"items" jsonschema:"Curated stops in execution or data-flow order from entry point to outcome; not raw search matches"`
}

type knowledgeCitation struct {
	SpaceID  string `json:"space_id"`
	SourceID string `json:"source_id"`
	Version  string `json:"version"`
	Chunk    int    `json:"chunk"`
}

type knowledgeArgs struct {
	Action    string              `json:"action" jsonschema:"list, search, read, read_note, table, aggregate, save_note, pin_note, jobs, cancel_job, or retry_job; scope is enforced by the host"`
	Revision  int                 `json:"revision,omitempty" jsonschema:"Expected current note revision when editing"`
	Pinned    bool                `json:"pinned,omitempty"`
	Version   string              `json:"version,omitempty" jsonschema:"Optional retained source version for historical evidence inspection"`
	Query     string              `json:"query,omitempty"`
	SourceID  string              `json:"source_id,omitempty"`
	SourceIDs []string            `json:"source_ids,omitempty" jsonschema:"Optional narrowing to selected sources"`
	First     int                 `json:"first,omitempty" jsonschema:"First one-based chunk or table row"`
	Last      int                 `json:"last,omitempty" jsonschema:"Last one-based chunk or table row"`
	Limit     int                 `json:"limit,omitempty"`
	TableName string              `json:"table_name,omitempty"`
	Column    int                 `json:"column,omitempty" jsonschema:"One-based numeric column for aggregate"`
	ID        string              `json:"id,omitempty" jsonschema:"Existing note or job ID"`
	Title     string              `json:"title,omitempty"`
	Body      string              `json:"body,omitempty" jsonschema:"Markdown note content"`
	Citations []knowledgeCitation `json:"citations,omitempty"`
}
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
		return json.NewEncoder(os.Stdout).Encode(map[string]any{"version": version, "bridge_protocol": protocol, "knowledge_protocol": 1})
	}

	if len(os.Args) < 2 {
		return fmt.Errorf("usage: aero-mcp serve|call --socket PATH [METHOD JSON]")
	}

	flags := flag.NewFlagSet(os.Args[1], flag.ContinueOnError)
	socket := flags.String("socket", connectionEnv("SOCKET"), "Aero instance socket")
	toolsets := flags.String("tools", "", "Comma-separated tool sets: tasks, reports, reading, knowledge")

	readingOnly := flags.Bool("reading-only", false, "Expose only reading-list tools")

	knowledgeOnly := flags.Bool("knowledge-only", false, "Expose only scoped knowledge tools")
	if err := flags.Parse(os.Args[2:]); err != nil {
		return err
	}

	selected, err := selectToolsets(*toolsets, *readingOnly, *knowledgeOnly)
	if err != nil {
		return err
	}

	c := client{socket: *socket, credential: connectionEnv("CREDENTIAL")}
	if c.socket == "" || c.credential == "" {
		return fmt.Errorf("socket and AERO_MCP_CREDENTIAL are required")
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

		for _, name := range selected {
			toolsetsByName[name](server, c)
		}

		return server.Run(context.Background(), &mcp.StdioTransport{})
	default:
		return fmt.Errorf("unknown command %q", os.Args[1])
	}
}

func connectionEnv(name string) string {
	if value := os.Getenv("AERO_MCP_" + name); value != "" {
		return value
	}

	return os.Getenv("AERO_TASK_" + name)
}

func selectToolsets(value string, readingOnly, knowledgeOnly bool) ([]string, error) {
	if (readingOnly && knowledgeOnly) || (value != "" && (readingOnly || knowledgeOnly)) {
		return nil, fmt.Errorf("--tools, --reading-only and --knowledge-only cannot be combined")
	}

	if readingOnly {
		value = "reading"
	}

	if knowledgeOnly {
		value = "knowledge"
	}

	if value == "" {
		value = "tasks,reports,reading"
	}

	var selected []string

	seen := map[string]bool{}

	for _, name := range strings.Split(value, ",") {
		name = strings.TrimSpace(name)
		if _, ok := toolsetsByName[name]; !ok {
			return nil, fmt.Errorf("unknown tool set %q", name)
		}

		if !seen[name] {
			selected = append(selected, name)
			seen[name] = true
		}
	}

	return selected, nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
