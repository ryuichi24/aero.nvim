package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type browserOpenArgs struct {
	URL string `json:"url" jsonschema:"URL with a scheme or existing HTML file path; relative paths resolve in this session's worktree"`
}

type browserPageArgs struct {
	PageID string `json:"page_id" jsonschema:"Opaque page_id returned by aero_browser_open or aero_browser_pages; never use another worktree's page"`
}

type browserActionArgs struct {
	PageID    string  `json:"page_id" jsonschema:"Explicit page_id returned by browser open/pages"`
	Action    string  `json:"action" jsonschema:"snapshot, screenshot, click, fill, press, wait, or scroll"`
	Ref       string  `json:"ref,omitempty" jsonschema:"Element reference from the latest snapshot, such as @e1; required for click/fill"`
	Text      *string `json:"text,omitempty" jsonschema:"Text to fill or wait for; empty text clears an input"`
	Key       string  `json:"key,omitempty" jsonschema:"Key or chord for press, such as Enter"`
	Direction string  `json:"direction,omitempty" jsonschema:"Scroll direction: up, down, left, or right"`
	Amount    *int    `json:"amount,omitempty" jsonschema:"Scroll distance in pixels, 1..5000; default 500"`
}

func registerBrowserTools(server *mcp.Server, c client) {
	addBrowserTool[browserOpenArgs](server, c, "browser_open", "Open a page in this session's worktree browser, waiting for readiness without moving user focus. If terminal-browser is missing, explain the returned installation instructions to the user before retrying.")
	addBrowserTool[readArgs](server, c, "browser_pages", "List page targets belonging to this session's worktree browser. Use explicit page_id values for actions.")
	addBrowserTool[browserActionArgs](server, c, "browser_action", "Inspect or interact with an explicit worktree page. Snapshot provides element references; screenshot returns an image. Closed/restarted targets require rediscovery. Finish with aero_browser_done.")
	addBrowserTool[browserPageArgs](server, c, "browser_done", "Release the agent-control indicator after finishing work on this page's browser.")
}

func addBrowserTool[T any](server *mcp.Server, c client, method, description string) {
	mcp.AddTool(server, &mcp.Tool{Name: "aero_" + method, Description: description},
		func(ctx context.Context, _ *mcp.CallToolRequest, args T) (*mcp.CallToolResult, any, error) {
			data, err := c.call(ctx, method, args)
			if err != nil {
				var details map[string]any

				_ = json.Unmarshal([]byte(err.Error()), &details)

				return &mcp.CallToolResult{IsError: true, StructuredContent: details, Content: []mcp.Content{&mcp.TextContent{Text: err.Error()}}}, nil, nil
			}

			var result map[string]json.RawMessage
			if err := json.Unmarshal(data, &result); err != nil {
				return nil, nil, fmt.Errorf("invalid browser response: %w", err)
			}

			var content []mcp.Content

			if image, ok := result["image"]; ok {
				var payload struct {
					MIMEType string `json:"mime_type"`
					Data     string `json:"data"`
				}
				if err := json.Unmarshal(image, &payload); err != nil {
					return nil, nil, fmt.Errorf("invalid browser image: %w", err)
				}

				pixels, err := base64.StdEncoding.DecodeString(payload.Data)
				if err != nil {
					return nil, nil, fmt.Errorf("invalid browser image encoding: %w", err)
				}

				content = append(content, &mcp.ImageContent{MIMEType: payload.MIMEType, Data: pixels})

				delete(result, "image")
			}

			text, err := json.Marshal(result)
			if err != nil {
				return nil, nil, err
			}

			content = append(content, &mcp.TextContent{Text: string(text)})

			return &mcp.CallToolResult{StructuredContent: result, Content: content}, nil, nil
		})
}
