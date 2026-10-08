# Aero host tools

This directory is the Go monorepo for Aero's host-side adapters. `go.work`
connects two independently buildable modules:

- `mcp/`: `aero-mcp`, the agent task MCP server.
- `companion/`: `aero-companion`, the mobile web bridge with its frontend under
  `companion/web/`.

The companion's **Reports** tab lists created reports for the selected worktree,
using Aero's configured report storage (including reports outside the worktree).
Select a report to preview rendered Markdown, use **Show source** to read the raw
text, or **Fullscreen** for a larger preview. **Refresh** reloads the report list
and content after an agent updates a report.

The companion's **Source** tab lets paired devices select a worktree, expand
nested folders in a persistent file tree, and read files with syntax highlighting
and line numbers. Markdown files open in preview mode with a source toggle.
It defaults to the selected session's worktree and remembers your position when
switching tabs. Use **Refresh** to reload changes from disk.
Source browsing requires a connected Neovim host and supports UTF-8 text files up
to 2 MiB.

The companion's session transcript includes **Assign board** for attaching an
idle ACP conversation to a saved workspace board. Session lists and transcripts
show board/ticket assignments and the assigned ticket's committed state, shared
with the Neovim dashboard and panel. See [task-agent setup](../docs/agent-tasks.md#assign-a-board-from-mobile).

The transcript's **Agent todos** panel follows the latest ACP plan or
`todowrite`/`todoread` tool update live. It shows completion progress, the items
currently being worked on, statuses, and priorities when supplied by the agent.
The panel stays above the scrolling logs, including in **Fullscreen logs**, and
can be collapsed using its heading. Plan and todo tool entries in the history
also render as readable lists.

`scripts/` packages both tools into the ignored `dist/` directory. The shared
version comes from `../release.json`; root Makefile commands build and test the
workspace.

From the repository root:

```sh
make build-all
make check-all
make release
```

From this directory, after building the companion frontend:

```sh
go test ./mcp/... ./companion/...
```

See [development and releases](../docs/releasing.md) for requirements and
publishing instructions.
