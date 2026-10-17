# aero.nvim

Manage Git workspaces, worktrees, and AI coding agents from Neovim. Run OpenCode,
Claude Code, or Codex beside your code, switch between isolated checkouts, and track
work on Markdown Kanban boards—all using familiar Vim buffers and motions.

**Requires Neovim 0.11+, Git, and the agent CLI you want to use.**
Kanban boards additionally require [Mike Farah's `yq` v4](https://github.com/mikefarah/yq).

## Installation

### lazy.nvim

```lua
{
  "ryuichi24/aero.nvim",
  cmd = "Aero",
  keys = {
    { "<leader>aa", "<cmd>Aero<cr>", desc = "Aero dashboard" },
    { "<leader>ap", "<cmd>Aero pick<cr>", desc = "Pick agent session" },
  },
  opts = {},
}
```

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({ "https://github.com/ryuichi24/aero.nvim" })
require("aero").setup({})

vim.keymap.set("n", "<leader>aa", "<cmd>Aero<cr>", { desc = "Aero dashboard" })
vim.keymap.set("n", "<leader>ap", "<cmd>Aero pick<cr>", { desc = "Pick agent session" })
```

`setup()` is optional when loading Aero directly; `:Aero` uses defaults without it.
For a local checkout, use `{ dir = "/path/to/aero.nvim", opts = {} }` with lazy.nvim.

### Agent setup

Install your preferred agent and make its executable available on Neovim's `PATH`.

| Agent | Terminal key | ACP key | ACP launch command |
| --- | --- | --- | --- |
| [OpenCode](https://opencode.ai/docs/) | `o` | `O` | `opencode acp` |
| Claude Code | `c` | `C` | `npx -y @agentclientprotocol/claude-agent-acp` |
| Codex | `x` | `X` | `npx -y @agentclientprotocol/codex-acp` |

Terminal sessions run the agent's own CLI interface. **ACP** sessions use the
[Agent Client Protocol](https://agentclientprotocol.com) for native Neovim transcript
and prompt buffers. The default Claude and Codex ACP commands require Node.js/npm
for `npx`; OpenCode provides its own ACP server.

### Quick start

1. Open Neovim in a Git repository and run `:Aero add`.
2. Run `:Aero` to open the dashboard.
3. Move to a worktree and press an agent key above to open a session.
4. Press `g?` in the dashboard for its keymap reference.

## Features

### Workspace and worktree dashboard

Browse **workspaces → worktrees → agent sessions** in a tree-shaped buffer.
Register repositories, create or remove worktrees, and manage multiple agents per checkout.

```text
▾ api-server ~/dev/api-server
  ▾ main (main)
    ● opencode         idle
  ▾ feat/auth
    ◐ claude-agent-acp busy
▸ web ~/dev/web
```

Press `a` on a workspace to create a worktree, or on a worktree to create a session.
Use `e` to open its code pane and `P` to pull its upstream with `git pull --ff-only`.

[Dashboard commands and keys](docs/workspaces.md)

### Worktree-specific tabs and shells

Each worktree gets a tab with its own working directory, code windows, and agent panel.
Switching worktrees restores the last file or directory and cursor position, including
Oil directory buffers. `:Aero term` toggles a worktree-specific shell below the code;
hiding it keeps the process running.

[Worktree tabs, buffers, and terminals](docs/workspaces.md#worktree-tabs-and-remembered-buffers)

### Agent panel, activity, and fullscreen

Agents open beside your code. ACP sessions show live activity and permission requests;
terminal busy/idle status is inferred from output. Use `:Aero panel` to toggle the panel,
`:Aero prompt` to focus input, and `:Aero pick` to switch sessions.

Use `:Aero sessions` for a searchable popup of active AI sessions across worktrees.
Sessions are grouped under worktree headings. Each session row shows its name,
agent, and live status (idle, busy, or waiting),
including ACP activity such as thinking or the current tool. The popup opens in
normal mode: use `j`/`k` to select and press `i` to enter insert mode and type to
filter. `↑`/`↓` or `Ctrl-n`/`Ctrl-p` also select sessions in either mode. Press
`Enter` to open the worktree and focus its session panel. `Esc` returns from
filtering to normal mode; `q` in normal mode closes the popup. In insert mode,
`q` is ordinary search text. Stopped and exited sessions are
excluded; use `:Aero pick` to browse those too.

Use `:Aero prompts` (or `gP` in an ACP transcript) to review that session's
submitted prompts in chronological order. The selected prompt is previewed in full;
`Ctrl-d`/`Ctrl-u` scroll the preview, and `Enter` jumps to its chat log line.
Use `i` to filter, `j`/`k` to select, and `q` to close. Empty sessions report no prompts.

Use `:Aero inbox` for a searchable attention inbox across ACP sessions: pending
permissions, errors, and completed turns awaiting review. `Enter` opens the relevant
transcript and marks the event read; `r` marks it read without opening, and `d`
dismisses it. Events remain after a session becomes idle. The inbox tracks events
in the current Neovim instance; see [attention inbox](docs/workspaces.md#attention-inbox).

`:Aero worktrees` lists worktrees grouped by workspace, and `:Aero workspaces`
lists registered workspaces. Both use the same navigation and filtering controls;
`Enter` opens the selected checkout's code window (the root checkout for a
workspace). Call `aero.worktrees()` or `aero.workspaces()` from Lua keymaps.

Press `gF` or run `:Aero fullscreen` to expand the focused pane; toggle again to restore
the layout. Aero maps `<C-w>h/j/k/l` to resizing in Aero panes; use `<C-w>w` to switch
windows, or set `resize = false` to retain ordinary directional navigation.

[Panels, resizing, and fullscreen](docs/layout.md)

### Native ACP conversations

Read highlighted Markdown transcripts with distinct messages, thinking, tool calls,
command output, and permissions. Press `i` to open the prompt and send with `:w` or
`<C-s>`. Use `:Aero cancel` to stop a turn, `/model` or `/mode` to select agent-provided
controls, and `:Aero usage` for reported tokens, context usage, and fees.

[Agent setup and ACP controls](docs/agents.md)

[Mermaid previews in session logs and Markdown files](docs/markdown.md)

### Quote code and agent logs

Visually select code or agent output and press `<leader>aq`. Aero adds the text,
source, and line range to the agent's draft without submitting it. Edit the quote
and add your question before sending.

[Quoting selections and targeting sessions](docs/quoting.md)

### Markdown reports

Run `:Aero report` or use `/report` in an ACP prompt to select or create a worktree
report. Aero attaches its path and an instruction to read and update it to the draft.
Reports appear in the dashboard and remain available across restarts.

[Report workflow and storage](docs/reports.md)

### Persistent sessions and recovery

Aero saves workspaces, session registrations, ACP transcripts, terminal-agent scrollback,
and each worktree's last code path and cursor. Opening a saved session attempts to resume
its conversation. Saved ACP history stays readable even when the backend cannot resume.
Unsaved code contents are not saved across restarts.

[Session persistence and recovery](docs/persistence.md)

### Markdown Kanban boards

Track tasks on boards shared by all worktrees of a repository. Boards and tickets are
ordinary Markdown files with YAML frontmatter for priority, assignees, tags, due dates,
and estimates.

Install the Go-based `yq` v4 (`brew install yq`), then use `:Aero board new` to create
a board or `:Aero board` to open one. Each state is an editable column in a dedicated tab:

1. `dd` cuts a ticket row.
2. `<C-w>h` / `<C-w>l` switches columns.
3. `p` pastes into the destination.
4. `:w` in any column saves **all columns together**.

Type a new ticket title on a blank line in any state and use `:w` to create its Markdown
file. Press `<CR>` to edit a ticket's Markdown; `ga` also offers dialog-based creation.

[Kanban workflow, keys, and file format](docs/kanban.md)

### Task-agent integration (opt-in)

Enable `tasks.agent.enabled`, configure the `aero-mcp` executable, and press `gw` on
a saved ticket to assign it to a fresh ACP session in a chosen worktree. Aero registers
the task MCP server automatically and appends the assignment without submitting it.
The tools use revision checks and preserve conflicting user drafts.

| OS | Task-agent integration | MCP binary build targets |
| --- | --- | --- |
| macOS | Available via Unix-domain sockets | ARM64 (Apple Silicon), AMD64 (Intel) |
| Linux | Available via Unix-domain sockets | ARM64, AMD64 |
| Windows | Not yet supported; a compatible local bridge transport is required | AMD64 `.exe` cross-build only |

Cross-compilation does not establish native-platform runtime support. The workflow
runs Go tests on Linux; macOS ARM64 integration has also been tested locally.
OpenCode ACP is the initial task-agent adapter; terminal-provider assignment remains
a follow-up. Development revisions require a custom executable built with `make build`;
prebuilt release binaries need no Go runtime.

[Task-agent setup, installation, and limitations](docs/agent-tasks.md)

### Integrations and customization

Configure agents, pane sizes, shortcuts, persistence, and storage with `setup()`:

```lua
require("aero").setup({
  panel = { width = 80 },
  acp = { prompt_height = 12 },
  reports = { directory = "worktree" },
  tasks = { directory = "worktree" },
})
```

Lifecycle hooks support integrations such as opening new worktrees in Oil.
`require("aero").statusline()` provides a compact session-status summary.

[Configuration reference](docs/configuration.md) · [Lifecycle hooks and integrations](docs/integrations.md)

Run `:checkhealth aero` to check dependencies, and `g?` in a dashboard or board for help.

## Mobile companion

Run `:Aero companion install` to download and verify the matching release binary
on your Neovim host (macOS/Linux). Requires `curl` and `sha256sum` or `shasum`.
You can also download from [GitHub Releases](https://github.com/ryuichi24/aero.nvim/releases)
or build from source with `make build-companion`
using Go, Node.js, and pnpm. Release binaries embed the web UI and need no
Go or Node.js runtime; the phone only needs a browser.

Use `:Aero companion start` to automatically launch the Go bridge and show its
URL and six-digit pairing code in a popup. The embedded React/TypeScript UI lets
you monitor ACP agents from a phone, send queued follow-ups, cancel turns, and answer live
permissions. Supports external SSH tunnels and explicitly configured HTTPS over
local Wi-Fi/private VPNs. Paired devices are remembered across restarts.
Set `companion = { auto_start = true }` in `require("aero").setup()` to launch
the installed companion and show pairing automatically after setup.
See [mobile companion setup](docs/companion.md) for
pairing, revocation, startup, and reconnect limitations. The host and Neovim must
remain running.

## Development and releases

See the [architecture and reading guide](docs/architecture.md) for state ownership,
feature walkthroughs, and focused test commands. `make test-lua` runs the full
fixture-based Neovim suite; task tests require Mike Farah's `yq` v4 and Python 3.

The MCP and companion projects live under `apps/`, sharing `apps/go.work` and
the root `release.json` version. Use `make build-all` to build both tools, `make check-all`
to verify them, and `make release` to package both binary families.
See [host-tool development and releases](docs/releasing.md) for requirements
and publishing instructions.

## License

Licensed under the [MIT License](LICENSE).

## Worktree references

Use `:Aero reference` to collect reference files and folders for the selected
worktree (or the current worktree when editing code). Each worktree stores its
own references under `stdpath("data")/Aero/workspaces/<workspace>/<worktree>/references`
by default, alongside the worktree's reports and outside the Git checkout.

Expanded worktrees show a **References** section in the sidebar with their stored
files and folders (folders end in `/`). Press `Enter` or `l` on a folder to expand
its children inline in the sidebar; nested folders work the same way. Press `h`
to collapse a folder or move to its parent. Files open in the editor. Select
**Add +** (or press `a` on a reference row) to launch the finder for that
worktree. The list refreshes after transfers. Use the usual `l`/`h`/`Tab`
controls to expand or collapse it, or `:Aero collapse reference` to collapse all
reference sections.

Press `d` on a reference item in the sidebar to delete it after confirmation.
Press `N` to rename a reference file or folder, including nested items. Existing
names are never overwritten, and renamed folders retain their expanded state.
In supported input UIs (Dressing/Snacks), renaming a file preselects only its
name, leaving the final extension intact; folder names are selected in full.
Deleting a folder removes its stored contents recursively. This removes only the
stored reference copy. The finder and staging popup show the target worktree;
the finder also shows the directory you are currently browsing.

```lua
require("aero").setup({
  reference_finder = {
    home = "~/Documents", -- where the finder starts
    directory = "data", -- scoped storage under stdpath("data")/Aero/workspaces
  },
})
```

`directory` can also be a path (relative paths resolve inside the worktree), or a
function receiving the worktree path and returning an
exact directory path. Use a distinct path per worktree to retain isolation.
Existing default `context` storage directories are reused when no `references`
directory exists, preserving existing files and paths in saved prompts. Explicit
custom storage paths continue to be used as configured.
The former `:Aero context`, `:Aero collapse context`, and `/context` commands
remain accepted as legacy aliases; new menus and completions use **reference**.

The finder supports `Enter`/`l` to enter a folder and `-`/`h` to go to its parent.
Press `y` to mark a file or folder for copying, `d` to mark it for cutting, and
`u` to unmark or unstage an item. These actions also support visual selections.
Hidden files are included. Marks survive navigation between directories.

Run `:w` to stage marked items in the persistent popup below the finder. You can
keep browsing and saving to build the stack. Press `q` or `Esc` to finish: saved
items are transferred into the reference folder, and unsaved marks are discarded.
Sources marked with `d` are removed only when transferred on exit. Existing
destination names and overlapping source selections are rejected rather than
overwritten; transfer errors keep the finder open so you can resolve them and retry.

In an ACP prompt, submit `/reference` to select a stored file or folder. Its absolute
path is appended to the draft with an instruction to read it for reference; send
the draft when ready. Choose **Add reference +** in that picker to open the finder.

### Companion UI

Open **Workspace → References**, or **Review → References for this worktree** from a
conversation. The companion uses the same reference storage and `reference_finder.home`
configuration as Neovim. Expand folders inline, preview text/Markdown, and select
an item to rename or delete it. Deleting a folder removes its stored contents.

**Add reference** opens a finder for files on the **Neovim host**, starting at your
configured home directory. Mark items with **Copy**/`y` or **Cut**/`d`, then
**Save selections** (or Ctrl/Cmd-S) to add them to the persistent staging panel.
**Finish finder** transfers saved selections into the displayed worktree's
reference folder; unsaved selections are discarded. **Unmark**/`u` and **Unstage**
remove selections, while **Discard finder** exits without transferring anything.
The target worktree and storage location stay visible as you browse.

In a companion prompt, type `/reference` or choose **Select reference** from Prompt
actions. Selecting an item drafts `/reference select <path>` without submitting it.
Add your instructions below that command and send when ready. Reference mutations
use the companion's existing operation receipts and identical-retry flow.

#### Companion reference security

Remote filesystem browsing and imports are disabled by default (`roots = {}`).
Paired devices can still browse, attach, rename, and delete items already in a
worktree's reference folder. `reference_finder.home` is a starting directory, not an access
boundary.

To enable remote imports from explicit source directories without changing the
local Neovim finder:

```lua
require("aero").setup({
  reference_finder = { home = "~/Documents" },
  companion = {
    reference_finder = {
      roots = { "~/Documents", "~/Projects/reference" },
      allow_cut = false,
    },
  },
})
```

Allowed roots are checked on the host for directory browsing, imported files,
and recursively imported children, including resolved symlink targets. An empty
`roots = {}` (the default) disables remote source browsing/imports; `roots = false`
explicitly opts into unrestricted access. `allow_cut = true` (the default)
preserves cut support within the allowed roots;
`false` enforces copy-only imports even for direct API requests.
The finder offers an allowed-root selector when restrictions are enabled. If
`reference_finder.home` falls outside those roots, it starts at the first allowed root.

The earlier setup keys `context` and `companion.context` are accepted as aliases.
If both old and new keys are supplied, the `reference_finder` settings take precedence.

Companion transfers run asynchronously, scan before writing, reserve destinations
exclusively, and copy all items before removing any cut sources. Changed sources
are rejected, and failures before cut completion clean up only newly-created copies.
If removal fails after a cut has begun, completed copies are retained to avoid data
loss. Conflicting mutations to the same reference directory are rejected while a
transfer runs. Receipt fingerprints bind the action, paths, and transferred items.

Default resource limits under `companion.reference_finder` are:

| Setting | Default |
|---|---|
| `max_entries` | 100,000 recursive source entries |
| `max_bytes` | 1 GiB of source file data |
| `max_depth` | 128 nested directory levels |
| `timeout_ms` | 120,000 ms for scanning/copying |
| `max_listing_entries` | 10,000 host finder entries per directory |

Each limit accepts a positive integer, or `false` to disable that limit. Increase
the relevant limit when importing larger references. A timed-out HTTP response
does not restart the transfer: **Retry identical action** retrieves its receipt.
**Cancel reference transfer** requests cancellation while scanning/copying; retry
the original action to collect the final outcome. Once verified cut-source removal
starts, cancellation is refused so it cannot interrupt that completion phase.
