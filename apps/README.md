# Aero host tools

This directory is the Go monorepo for Aero's host-side adapters. `go.work`
connects two independently buildable modules:

- `mcp/`: `aero-mcp`, the agent task MCP server.
- `companion/`: `aero-companion`, the mobile web bridge with its frontend under
  `companion/web/`.

The companion uses four main destinations: **Home**, **Sessions**, **Inbox**, and
**Workspace**. Home summarizes attention and running agents, offers quick actions,
and remembers recently opened and pinned sessions. Sessions defaults to a searchable
flat list with status filters; **Group by workspace/worktree** exposes the hierarchy
and its management actions. New session creation is available directly from Home.

Session details separate **Conversation**, **Artifacts**, and **Details**. Conversation
keeps prompts and permission responses accessible; Artifacts contains screenshots and
recordings; Details contains usage, todo progress, assignment, and session management.
The composer’s **Prompt actions** exposes report, model, mode, and export commands.
Existing drafts are preserved when choosing report workflows from Workspace.

The **Workspace** hub shares one explicit worktree context across **Reports**,
**Changes**, and **Source**. Opening another session does not change this review context;
session-specific review links explicitly switch it. Browser Back and reload preserve
the main route, session selection, and session drafts. Visited readers retain their
file selections and position during navigation. Device settings include dark/light
appearance, zoom, fullscreen attention, and unpairing.

The companion's **Workspace → Changes** view lets you choose a worktree to browse
its changed files, including untracked files. Select a file to read its highlighted unified
diff. Partially staged files appear in both groups with their corresponding diffs.
The view refreshes every five seconds; **Refresh** reloads it immediately.

The companion's **Workspace → Reports** view lists created reports for the selected worktree,
using Aero's configured report storage (including reports outside the worktree).
Select a report to preview rendered Markdown, use **Show source** to read the raw
text, or **Fullscreen** for a larger preview. **Refresh** reloads the report list
and content after an agent updates a report. Search filters report names within the
displayed folders. **Create report with an agent** opens the selected worktree's
session composer with the existing report picker/creation workflow.

The companion's **Workspace → Source** view lets paired devices select a worktree, expand
nested folders in a persistent file tree, and read files with syntax highlighting
and line numbers. Markdown files open in preview mode with a source toggle.
It uses the shared review worktree and remembers your position when switching views.
On phones, readers open separately from their file list with an explicit Back button.
Use **Refresh** to reload changes from disk.
Source browsing requires a connected Neovim host and supports UTF-8 text files up
to 2 MiB.

The companion's session transcript includes **Assign board** for attaching an
idle ACP conversation to a saved workspace board. Session lists and transcripts
show board/ticket assignments and the assigned ticket's committed state, shared
with the Neovim dashboard and panel. See [task-agent setup](../docs/agent-tasks.md#assign-a-board-from-mobile).

Session-labeled **todo notifications** follow live ACP plan and todo tool changes
for every session, including agents outside the selected transcript. Lower-right
popups show completion progress, current work, statuses, and priorities, and also
appear inside fullscreen views. Close an individual popup with its × button or
Escape while focused. The **Todos** button focuses the latest open popup or
reopens the most recent checklist after notifications close. Hovering or focusing
a popup pauses auto-close; leaving starts a fresh timeout. Initial connection
history does not trigger notifications. Plan and todo tool entries in the history
continue to render as readable lists.

Companion popups share Neovim's configuration: `acp.todo_notifications = false`
disables them, and `acp.todo_notification_timeout` sets milliseconds after the
latest todo change (default 15000; `0` keeps popups open until dismissed).

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
