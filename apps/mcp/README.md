# Aero MCP server

`aero-mcp` is the shared MCP adapter for Aero's task, report, reading-list,
and knowledge systems. It forwards authenticated requests to the Aero instance;
the host enforces the permissions of each session binding.

Set `AERO_MCP_SOCKET` and `AERO_MCP_CREDENTIAL` for the connection. `--socket`
overrides the socket environment variable. The older `AERO_TASK_SOCKET` and
`AERO_TASK_CREDENTIAL` variables remain fallback aliases.

Select tool sets explicitly when starting an MCP server:

```sh
aero-mcp serve --tools tasks,reports,reading
aero-mcp serve --tools reading
aero-mcp serve --tools knowledge
```

Available sets are `tasks` (boards and tickets), `reports` (findings reports),
`reading` (source walkthroughs), and `knowledge` (scoped research). Sets can be
combined; duplicate selections are ignored. Selection controls discovery, while
host-side binding checks still determine which operations are authorized.

Without `--tools`, the legacy `tasks,reports,reading` selection is preserved.
`--reading-only` and `--knowledge-only` remain compatibility aliases; selectors
cannot be combined with these aliases or each other.

For direct bridge requests, use `aero-mcp call METHOD 'JSON'` with the same
connection settings. Tool selection applies to MCP discovery, not direct calls.
