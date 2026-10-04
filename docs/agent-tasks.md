# Agent task integration (development)

Aero can bind a fresh ACP session to one persisted ticket. Lua remains responsible
for Markdown validation and writes; a standalone Go MCP adapter exposes the tools.
The initial transport supports macOS and Linux. Windows executable cross-builds
are packaging checks, not Windows bridge support.

## Setup

Build with Go 1.24 or newer (contributors only):

From the repository root:

```sh
make build # creates mcp/aero-mcp
make check # runs Go tests and vet
make clean # removes the built executable
```

Rebuild after Go changes. For a custom output location, run
`CGO_ENABLED=0 go build -o /absolute/path/aero-mcp ./cmd/aero-mcp` from `mcp/`.

```lua
require("aero").setup({
  tasks = {
    agent = {
      enabled = true,
      executable = vim.fn.expand("~/dev/personal/projects/aero.nvim/mcp/aero-mcp"),
      adapters = { "opencode-acp" },
    },
  },
})
```

Run `:checkhealth aero` to verify the exact executable and bridge version.
The development manifest is unpublished: `:Aero tasks install` requires a custom
build. Tagged releases must update `mcp/release.json` and publish matching assets;
the installer then downloads the exact release, verifies SHA-256, and installs
outside the plugin checkout under `stdpath("data")/Aero/bin/<version>`.
Installation uses curl and sha256sum or shasum. Runtime prebuilt users need no Go.

For published releases, a lazy.nvim build hook can call
`require("aero.tasks.install").install()`; vim.pack users can run
`:Aero tasks install` manually. An explicit executable supports offline use.

## Work on a ticket

Save board and ticket edits, then press `gw` on a persisted board row, or run:

```vim
:Aero ticket work
:Aero ticket work <board-id> <ticket-id>
```

Choose the execution worktree, ACP adapter, and a new session name. The assignment
is appended to the prompt draft without submission. Board tabs are excluded from
worktree reuse. Title-only rows must be saved before assignment. Binding credentials
are runtime-only; assignments do not survive an Aero restart.

Available tools: `aero_list_boards`, `aero_get_board`, `aero_get_ticket`,
`aero_move_ticket`, `aero_update_ticket_body`, and `aero_update_ticket_metadata`.
Reads return committed Markdown, SHA-256 revisions, actual states, and local draft
indicators. Mutations require the revision returned by the read and an
`operation_id`. Movement accepts actual custom state names. A same-state move
without an ordering position does not rewrite or reorder the board; it may backfill
the ticket's state metadata when recovering a legacy document.

Conflicting drafts are never saved or discarded automatically. Board drafts block
movement; ticket drafts block ticket updates. Body and non-title metadata updates
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
verify the bridge and SDK tool discovery; real provider tool execution, terminal
provider configuration, and cross-restart reassignment need separate verification.
No busy/idle/exit event changes ticket progress.
