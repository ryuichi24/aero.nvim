# Agent task integration (development)

Aero can bind an ACP session to a board or one persisted ticket. Lua remains responsible
for Markdown validation and writes; a standalone Go MCP adapter exposes the tools.
The initial transport supports macOS and Linux. Windows executable cross-builds
are packaging checks, not Windows bridge support.

## Setup

Build with Go 1.24 or newer (contributors only):

From the repository root:

```sh
make build # creates apps/mcp/aero-mcp
make check # runs Go tests and vet
make clean # removes the built executable
```

Rebuild after Go changes. `make build` reads the required version from
the root `release.json` and embeds it in the executable (requires Python 3).
For a custom output location, run
`CGO_ENABLED=0 go build -ldflags '-X main.version=0.4.0' -o /absolute/path/aero-mcp ./cmd/aero-mcp`
from `apps/mcp/`, replacing `0.4.0` with the manifest's version if it changes.

```lua
require("aero").setup({
  tasks = {
    agent = {
      enabled = true,
      executable = vim.fn.expand("~/dev/personal/projects/aero.nvim/apps/mcp/aero-mcp"),
      adapters = { "opencode-acp", "claude-agent-acp", "codex-acp" },
    },
  },
})
```

Run `:checkhealth aero` to verify the exact executable and bridge version.
Unpublished development manifests require a custom build instead of
`:Aero tasks install`. Tagged releases must update the root `release.json` and publish matching assets;
the installer then downloads the exact release, verifies SHA-256, and installs
outside the plugin checkout under `stdpath("data")/Aero/bin/<version>`.
Installation uses curl and sha256sum or shasum. Runtime prebuilt users need no Go.

Maintainers: see [releasing Aero's host tools](releasing.md) for the shared manifest,
tagging, and publishing procedure.

For published releases, a lazy.nvim build hook can call
`require("aero.tasks.install").install()`; vim.pack users can run
`:Aero tasks install` manually. An explicit executable supports offline use.

## Work on a ticket

### Create tickets on an empty board

In an existing ACP session, submit `/new-ticket <requirements>`. Aero attaches
the task MCP server by reloading the same ACP conversation, without requiring an
existing ticket. It uses the workspace's only board, or asks you to choose when
there are multiple boards. The current board is preferred when available.
Enable `tasks.agent.enabled` and include your adapter in `tasks.agent.adapters`.
Attaching to an existing conversation requires ACP `session/load` support.

You can also start a fresh board-only session from a board, including an empty one:

```vim
:Aero board work
:Aero board work <board-id>
```

Then use `/new-ticket` in its prompt. Board-only sessions can read the board and
create tickets; ticket-specific reads, updates, and moves require a ticket-assigned
session. If there is no board yet, create and save one with `:Aero board new` first.

### Assign a board from mobile

In the companion app, open an ACP session's transcript and expand **Assign board**.
Choose a saved board from that session's workspace, then tap **Assign board**.
Task-agent integration must be enabled and the session's adapter must be allowed
by `tasks.agent.adapters` and support ACP `session/load`. Resume stopped sessions
first and wait for the agent to be idle. Save conflicting board drafts in Neovim.
Replacing an existing board or ticket assignment requires selecting
**Replace current board or ticket assignment**.

Assignment keeps the existing conversation, transcript, and prompt drafts. It
registers board-scoped MCP tools without submitting a prompt. You can then send:

> Turn our brainstorm into separate todo tickets, each with a description and
> acceptance criteria. Check for duplicates and create them without implementing them.

Use ordinary messages on mobile; editor-local slash commands remain unsupported.
Mobile prompts include the current assignment context so replacement supersedes
older assignment instructions in the conversation.

The companion session list and transcript show the assigned board and ticket.
Neovim shows assignment details beneath each dashboard session and in the agent
panel's winbar. Details include board/ticket titles and IDs and the ticket's
current committed board state. Saved assignments remain visible for stopped
sessions; missing documents are marked unavailable.

A session is bound to either a board or one ticket. A board-only session displays
**no assigned ticket** even after it creates several tickets; creation does not
automatically assign those tickets to the conversation.

### Implement an existing ticket

Save board and ticket edits, then press `gw` on a persisted board row, or run:

```vim
:Aero ticket work
:Aero ticket work <board-id> <ticket-id>
```

Choose **New session** or **Existing session**. For a new session, choose the
execution worktree, ACP adapter, and a session name. For an existing session,
choose a ready, idle or stopped/saved ACP conversation in the ticket's workspace.
The picker shows its name, adapter, status, and execution worktree; that worktree
is retained. Selecting a stopped session attaches the ticket and resumes its
saved conversation automatically. Sessions that have never started a conversation
and have no saved ACP conversation ID are excluded; choose **New session** instead.
The adapter must be allowed by `tasks.agent.adapters` and advertise ACP
`session/load` support. Busy sessions, pending session changes, and unsupported
adapters cannot be assigned; wait for readiness or choose a new session. For a
stopped session, Aero checks `session/load` support during initialization and
never falls back to creating a new conversation if resume fails.

Aero revalidates drafts and session eligibility after selection. Existing-session
assignment reloads the same ACP conversation with ticket-scoped MCP tools,
retaining its ID, transcript, usage, model/mode state, and existing prompt draft.
The assignment is appended to the prompt draft without submission. Board tabs are
excluded from worktree reuse. Title-only rows must be saved before assignment. Binding credentials
are runtime-only. Assignment identities (workspace root, board ID, and optional
ticket ID) are saved with the session when `persist_sessions` is enabled. On resume,
Aero validates the assignment and supplies a fresh MCP socket and credential before
loading the ACP conversation. Board-only sessions reconnect the same way. Missing
or ambiguous boards/tickets stop resume with an explicit error rather than silently
dropping task tools. Existing ticket sessions can recover their assignment from
Aero's generated assignment prompt in saved conversation history.

Replacing a board or ticket assignment requires **Replace assignment** confirmation.
Assigning the same ticket to a ready session again only appends fresh instructions;
it does not reload or rotate credentials. A stopped session is resumed even when
it already has the same ticket. Successful replacement revokes the superseded credential.
On failure, Aero revokes the failed-attempt credential and restores the previous
binding and provider MCP configuration without changing the persisted assignment.
An originally unbound session remains unbound. If the provider also rejects the
recovery reload, Aero stops the conversation and asks you to resume it rather than
send prompts with uncertain tool state. Assignment identity is persisted when
`persist_sessions` is enabled; sockets and credentials are never persisted and are
regenerated on resume. `:Aero board work` retains its fresh board-session workflow.
Failed stopped-session assignment leaves the previous saved assignment intact and
the session stopped, with the failed-attempt credential revoked. Instructions are
appended only after successful resume and are never submitted automatically.

If a resumed OpenCode conversation still claims the Aero tools are unavailable,
ask it to actually call `aero-tasks_aero_get_ticket` (or `aero-tasks_aero_get_board`
for a board-only session). A successful ACP resume alone does not verify tool use.
If the MCP connection is working but that conversation keeps repeating the old
unavailable-tool state, submit OpenCode's `/compact`, then retry the read-only
call. This refreshes the active conversation context while retaining its session
identity and saved history. This recovery was verified with OpenCode 1.18.34;
compaction is not a fix for a missing assignment or a failed MCP connection.

Available tools: `aero_list_boards`, `aero_get_board`, `aero_get_ticket`,
`aero_create_ticket`, `aero_move_ticket`, `aero_update_ticket_body`, and
`aero_update_ticket_metadata`.
Reads return committed Markdown, SHA-256 revisions, actual states, and local draft
indicators. Mutations require the revision returned by the read and an
`operation_id`. Movement accepts actual custom state names. A same-state move
without an ordering position does not rewrite or reorder the board; it may backfill
the ticket's state metadata when recovering a legacy document.

To create a ticket, the agent reads `aero_get_board`, then calls `aero_create_ticket`.

In a task-enabled ACP prompt, you can use Aero's local `/new-ticket` command
instead of spelling out the tool instructions:

```text
/new-ticket Add regression coverage for the edge case we discussed. Put it in todo.
```

Submit with `:w`, `<C-s>`, or normal-mode `<CR>`. Aero expands the command into
instructions to read the board, discover its states and revision, and create a
ticket through MCP with initial description and acceptance criteria. A bare
`/new-ticket` uses the conversation's follow-up context; the agent is instructed
to ask for clarification when needed. The expanded instructions appear in the
transcript. `<C-x><C-o>` completes the command. This creates the ticket without
asking the agent to implement it.

For a direct MCP call, the arguments are:

```json
{
  "operation_id": "create-follow-up-1",
  "expected_board_revision": "<board_revision from aero_get_board>",
  "title": "Add regression coverage",
  "target_state": "todo",
  "body": "## Description\n\nCover the newly discovered edge case.\n\n## Acceptance criteria\n\n- [ ] Regression test passes"
}
```

Creation appends a new ticket to an existing state on the assigned board. `body`
is required (an empty string is allowed) and supplies Markdown below the generated
title heading; Aero generates the ticket ID and frontmatter. The result is the
new committed ticket snapshot, including its ID, path, and revisions. The session
remains assigned to its original ticket; existing update tools still target that
original ticket. Board-only sessions remain bound to the board after creation.

Conflicting drafts are never saved or discarded automatically. Board drafts block
creation and movement; ticket drafts block ticket updates. Body and non-title metadata updates
can proceed alongside board-placement drafts. Generic ACP writes to the assigned
board and ticket are refused with guidance to use the tools. Direct shell writes
remain possible: this interface is not a filesystem sandbox.

The per-instance replay cache retains the last 256 mutation results. Reusing the
same operation ID and payload returns the original result; a changed payload is
rejected. Cache entries disappear after eviction or restart. A timeout does not
prove failure: reread committed data before retrying when the outcome is unknown.
The bridge uses protocol 1, newline-framed JSON, 1 MiB messages, a bounded 32-request
queue, and serialized main-loop dispatch. Client deadlines are 30 seconds.

The same executable offers debugging calls:

```sh
AERO_TASK_CREDENTIAL=<runtime-credential> aero-mcp call --socket <socket> get_ticket
```

ACP descriptors are supplied for both new and loaded sessions that retain a runtime
binding. Fresh OpenCode ACP is the initial intended provider. Automated fixtures
verify the bridge, SDK tool discovery, and task reconnection across Neovim restarts;
real provider tool execution and terminal provider configuration need separate verification.
No busy/idle/exit event changes ticket progress.

## Report tasks

Set `task_type: report` in a ticket's YAML frontmatter to request investigation
and a Markdown report. New tickets default to `task_type: general`; general tasks
follow the ticket's requirements. `task_type: implementation` explicitly requests
implementation. Older tickets without the field remain valid.
The board's metadata editor (`gi`) exposes
`task_type`; enter the JSON string `"report"`.

Assign the saved ticket through the normal task-agent workflow and select its
execution worktree. The agent reads `metadata.task_type` with `aero_get_ticket`,
investigates, and calls `aero_create_report`:

```json
{
  "operation_id": "investigation-report-1",
  "name": "investigation-findings.md",
  "body": "# Findings\n\nSummary, evidence, and recommendations.\n"
}
```

Aero creates the file under that execution worktree's configured
`reports.directory`, including custom or data-directory storage, and returns
`name`, `path`, `worktree`, `board_id`, `ticket_id`, and `committed`. The report
appears in the dashboard's Reports section. The agent records its returned path
in the ticket body through `aero_update_ticket_body`.

The tool accepts a filename rather than an arbitrary destination path, appends
`.md` when needed, and never overwrites an existing report. Identical retries
with the same operation ID return the original result during the current Aero
runtime (subject to the bounded operation cache); changed arguments with the
same ID are rejected. After restart or cache eviction, an existing filename
remains protected and a new report needs a new filename.

`aero_create_ticket` also accepts optional `task_type`, and
`aero_update_ticket_metadata` can change it. Report creation requires a live
ticket binding with an execution worktree. Creating a report does not move the
ticket or submit the agent prompt automatically.
