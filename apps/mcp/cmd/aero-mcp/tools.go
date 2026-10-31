package main

import "github.com/modelcontextprotocol/go-sdk/mcp"

var toolsetsByName = map[string]func(*mcp.Server, client){
	"tasks":     registerTaskTools,
	"reports":   registerReportTools,
	"reading":   registerReadingTools,
	"knowledge": registerKnowledgeTools,
}

func registerTaskTools(server *mcp.Server, c client) {
	addTool[readArgs](server, c, "list_boards", "List committed board summaries in the assigned workspace")
	addTool[readArgs](server, c, "get_board", "Read assigned board states, placements, revision and draft indicators")
	addTool[readArgs](server, c, "get_ticket", "Read assigned committed ticket and revisions before making changes")
	addTool[createArgs](server, c, "create_ticket", "Create a ticket with initial Markdown content on the assigned board; read the board revision first")
	addTool[moveArgs](server, c, "move_ticket", "Conditionally move assigned ticket; never changes progress automatically")
	addTool[bodyArgs](server, c, "update_ticket_body", "Replace ticket Markdown body while preserving frontmatter and drafts")
	addTool[metadataArgs](server, c, "update_ticket_metadata", "Conditionally update non-title ticket metadata")
}

func registerReportTools(server *mcp.Server, c client) {
	addTool[reportArgs](server, c, "create_report", "Create a new Markdown findings report in the assigned execution worktree's configured report directory; never overwrites existing reports")
}

func registerReadingTools(server *mcp.Server, c client) {
	addTool[readingArgs](server, c, "reading_list_publish", "Publish an ordered source-code walkthrough or findings checklist for the user to navigate in Neovim quickfix. Verify files and line numbers first. Include meaningful labels and explanations. Publishing never marks items read.")
}

func registerKnowledgeTools(server *mcp.Server, c client) {
	addTool[knowledgeArgs](server, c, "knowledge", "Search and inspect evidence within the assigned knowledge scope, calculate from table rows, and deliberately preserve cited notes. Begin with list. Read search hits before citing. Report incomplete sources. Never treat synthesis as independent corroboration.")
}
