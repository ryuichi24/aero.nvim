# Markdown Kanban boards

Edit workspace-wide task boards with Vim motions and keep their source as ordinary Markdown.

[Back to README](../README.md)

## Setup and opening boards

Requires [Mike Farah's Go-based `yq` v4](https://github.com/mikefarah/yq) (MIT).
Python `yq` and older versions are incompatible; no Python helper is needed.

```sh
brew install yq
yq --version
```

```lua
require("aero").setup({
  tasks = {
    yq = "yq", -- defaults to AERO_TASKS_YQ when set, otherwise yq
    directory = "data",
    states = { "backlog", "todo", "in progress", "review", "test", "done" },
    terminal_states = { "done" },
    estimate_unit = "points",
    column_width = 32,
  },
})
```

`:checkhealth aero` checks the executable/version. State lists are replaced wholesale
and apply to new boards; existing boards derive states from their files. Due dates
before today's UTC date are overdue except in `terminal_states`. Estimates use the
configured workspace-wide unit (default **points**).

`:Aero board` picks/opens a board; `:Aero board new` creates one. Workspace **Boards**
rows are independent of worktrees/sessions. `<CR>` opens the view; `e` opens source.
`a` or **New +** creates a board; `N` renames it without changing its folder.
`d` confirms permanent deletion of the entire board folder, including tickets.

## Editable columns

Each state is an editable buffer in a column window. Each ticket occupies one physical
line (`ticket-id  title`) with virtual metadata. IDs are concealed but travel with cut/paste;
`:setlocal conceallevel=0` reveals them. Full titles remain available through horizontal
scrolling. Headers show state counts and archive/stale status; `g?` shows summary,
tags, mappings, and diagnostics.

Each board has a reusable full-width tab, without the dashboard/agent panel. Reopening
focuses its tab. `q` returns to the originating tab after saving/discarding edits.
Closing retains state buffers, so reopening restores the editing session.

### Move and save

`dd` cuts a row, `<C-w>h/l` switches columns, and `p`/`P` pastes. Visual cut/paste
moves multiple tickets. `m` and `gK/gJ` stage movement/reordering. **`:w` in any column
saves all columns together**, including hidden ones, in one board Markdown update.
Ticket files remain unchanged.

Missing, duplicate, unknown, or edited rows reject the whole save and keep the draft.
Do not edit IDs/titles here; rename with `N`. Cutting without pasting is not deletion;
use `gd/gD`. Explicit removal, creation, and metadata/state edits require a clean draft.

Undo/redo is column-local. A cross-column move edits two buffers; undoing one can
temporarily create missing/duplicate rows. After saving, undo creates a new draft;
save again to persist the reversal. External changes never overwrite dirty columns;
stale saves fail. Use `e` to compare source or `R` to explicitly discard/reload all columns.

### Edit ticket Markdown

`<CR>` opens the real ticket in a centered floating window above the board. `:w` saves,
`:wq` saves/closes, and `:q` closes. Normal buffer rules apply: `hidden` retains a
modified draft on close; otherwise Vim asks to save. `:e!` explicitly discards edits.
The float adapts to editor size. `e` opens board source in a separate code split.

### Column sizing

`tasks.column_width` (default 32) controls how many states fit. Resizes rebalance columns;
inactive tabs adapt on entry. `[s`/`]s` reach off-screen states while retaining buffers.
Closing a column retains edits; a wiped state buffer blocks saving until reload.
Tabs for the same board share the editing session; resizing does not replace drafts.

## Keys and commands

| Key | Action |
| --- | --- |
| `[s` / `]s` | Previous / next state, including hidden columns |
| `h/j/k/l`, `dd`, `p`, `u`, `<C-r>` | Ordinary Vim editing and column-local undo/redo |
| `<CR>` / `e` | Edit ticket in float / board source |
| `ga` | Create ticket in selected state |
| `m` | Stage move to chosen state; save with `:w` |
| `gK` / `gJ` | Stage earlier / later ordering |
| `N` | Rename ticket, or board on empty row |
| `gi` | Edit ticket/board metadata with JSON values |
| `gs` | Add, rename, reorder, remove states; populated removal needs a destination |
| `gd` | Remove reference, preserving ticket file |
| `gD` | Confirm permanent ticket deletion |
| `go` | Recover orphan into a state of its owning board |
| `gA` | Archive/unarchive board, keeping files |
| `R` | Reload with confirmation before discarding column drafts |
| `q` / `g?` | Close tab / show help |

`:Aero ticket new` creates in the active board's selected state; `:Aero ticket move`
chooses a state. Override mappings using `tasks.keymaps`, with `false` to disable.
Clean views refresh on writes/focus; dirty views retain drafts. Cursor movement does
not read files; typing updates cached metadata with a debounce, and resizing redraws
decorations without rereading Markdown.

## Storage

```text
stdpath("data")/Aero/workspaces/<workspace-name-hash>/tasks/
  <board-title>-board-<stable-id>/
    board.md
    tickets/task-<stable-id>.md
```

All worktrees share this directory. Each board owns its tickets; cross-board transfers
and links are rejected. Discovery does not create files.

| `tasks.directory` | Location |
| --- | --- |
| `"data"` | Default above |
| `"worktree"` | Main checkout's `<workspace.root>/.aero/tasks` |
| Absolute root | `<root>/<workspace-name-hash>/tasks` |
| Relative path | Exact directory relative to workspace root |
| Function `(workspace_root)` | Exact returned directory, relative to root if needed |

Tasks do not change report/state formats or write metadata into `state.json`.
Changing directories selects a different store; migrate by moving whole board folders.
Forgetting a workspace preserves task files.

## Markdown and YAML format

Example `board.md`:

```markdown
---
aero_type: board
schema_version: 1
id: board-example
title: "Product"
description: "Release work"
tags: ["release"]
archived: false
---

# Product

Notes remain ordinary Markdown.

## todo

- [Fix startup](tickets/task-example.md)

## done
```

Example `tickets/task-example.md`:

```markdown
---
aero_type: ticket
schema_version: 1
id: task-example
title: "Fix startup"
priority: high
assignees: ["ryu"]
tags: ["performance"]
due_date: "2026-10-15"
estimate: 3
---

# Fix startup

## Description

Investigate startup latency.

## Acceptance criteria

- [ ] Startup stays below the agreed budget.
```

Both types require `aero_type`, `schema_version: 1`, a stable nonempty `id`, and a
nonempty single-line `title`. Optional `created_at/updated_at` are quoted UTC timestamps
(`YYYY-MM-DDTHH:MM:SSZ`); creation fills them and changes update `updated_at`.
Tags/assignees are string lists; priority is `low/normal/high/urgent`; estimates are
finite nonnegative numbers. Invalid types/dates, duplicate keys, unsupported tags,
and unsupported versions are rejected before writes.

Frontmatter titles are authoritative. Renaming updates a matching body heading/link
label but keeps folders/filenames stable. Level-two headings outside fences define
states; heading and link order define state/ticket order. Status is not duplicated
in ticket frontmatter. References must resolve inside the board's direct `tickets/`
directory. Generated labels escape brackets/backslashes and destinations are
percent-encoded. Symlinked board folders and ticket aliases are rejected.

Directly edit descriptions, acceptance criteria, and custom frontmatter. `yq` round-trip
edits preserve unknown fields, comments, anchors/aliases, and block/flow styles; targeted
Markdown edits preserve other body text. YAML whitespace/indentation may normalize and
edited values may use JSON-compatible YAML. Comments on replaced collection elements
remain as standalone comments. Metadata is passed as data to fixed expressions and
revalidated; alias-breaking edits are refused. Block/flow top-level mappings are supported.

## Conflicts and recovery

Mutations hold an exclusive `<task-directory>/.aero-tasks.lock` containing host, PID,
creation time, and ownership token. Live owners are never displaced; dead same-host
PIDs recover automatically. Remote/unreadable/ambiguous locks need manual removal
after checking that the owner is gone.

Sources are reread under lock, modified Neovim buffers are rejected, original contents
are compared, and writes use exclusive same-directory temporary files plus atomic rename.
Unmodified buffers refresh. External editors do not honor Aero locks: detected conflicts
stop updates, but a small comparison-to-replacement filesystem race remains.

Markdown has no multi-file transaction. Ticket creation writes the file before its
reference; failed board updates leave a recoverable orphan (`go`). Renaming writes
metadata before the label; failure is reported and the frontmatter title remains
authoritative. Deletion removes the reference first; failure leaves an orphan.
No automatic cleanup removes user-authored tickets.

## Lua APIs

UI: `require("aero").board(action, workspace)`, `.ticket(action)`, and
`.open_board(workspace, board_path)`. Context comes from dashboard selection, task
buffer, active repo/worktree, or active board; ambiguity prompts for a workspace.
Explicit workspace arguments are `{ root = "/path/to/main-checkout" }`.

The headless service returns a model/`true` or `nil, error`:

```lua
local tasks = require("aero.tasks")
local ws = { root = "/path/to/repository" }
local board = assert(tasks.create_board(ws, "Product", { tags = { "release" } }))
local ticket = assert(tasks.create_ticket(ws, board.path, "todo", "Fix startup", { priority = "high" }))
assert(tasks.move_ticket(ws, board.path, ticket.path, "review", 1))
assert(tasks.reorder_ticket(ws, board.path, ticket.path, 1))
assert(tasks.update_metadata(ws, board.path, ticket.path, { estimate = 3 }))
```

Other operations: `directory`, `list`, `read_board`, `read_ticket`, `rename_board`,
`rename_ticket`, `add_state`, `rename_state`, `reorder_state`, `remove_state`,
`remove_ticket` (fourth argument `true` permanently deletes), `archive_board`,
and `delete_board`. `move_ticket` can recover an orphan of the same board.
