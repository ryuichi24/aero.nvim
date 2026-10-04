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

## License

Licensed under the [MIT License](LICENSE).
