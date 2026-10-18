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

[Dashboard commands and keys](docs/workspaces.md)

### Review worktree changes

Use `:Aero review` or dashboard `gr` to browse staged, unstaged, and untracked
changes in a collapsible project folder tree. Compare committed branch changes with
`:Aero review <base-ref>`, open files, and quote a hunk or selected diff text into
an agent's draft for follow-up.

[Change review, feedback, and diff-viewer integration](docs/review.md)

### Worktree-specific tabs and shells

Each worktree gets a tab with its own working directory, code windows, and agent panel.
Switching restores the last file or directory and cursor position, including Oil buffers.
Use `:Aero term` for a worktree-specific shell that keeps running when hidden.

[Worktree tabs, buffers, and terminals](docs/workspaces.md#worktree-tabs-and-remembered-buffers)

### Agent panels and navigation

Keep agents beside your code, monitor their activity, and expand any pane with
`:Aero fullscreen`. Search active agents with `:Aero sessions`, review submitted
prompts with `:Aero prompts`, and find permissions or completed turns in `:Aero inbox`.
Use `:Aero worktrees` and `:Aero workspaces` to jump between checkouts.

[Panels, resizing, and fullscreen](docs/layout.md) · [Search and attention inbox](docs/workspaces.md#commands)

### Native ACP conversations

Read highlighted Markdown transcripts with distinct messages, thinking, tool calls,
command output, and permissions. Press `i` to open the prompt and send with
`<C-CR>` (Ctrl-Enter). Cancel turns, switch agent-provided models and modes, and inspect reported
token usage and fees without leaving Neovim.

[Agent setup and ACP controls](docs/agents.md) · [Mermaid previews](docs/markdown.md)

### Quote code and agent logs

Visually select code or agent output and press `<leader>aq`. Aero adds the text,
source, and line range to the agent's draft without submitting it.

[Quoting selections and targeting sessions](docs/quoting.md)

### Markdown reports

Build a draft with multiple actions: type `/report` or `/prompt` on its own line
and press Enter to open its picker, even when the draft already contains text.
Repeat `/prompt` to add more snippets, then send the combined draft with Ctrl-Enter.

Use `:Aero report` or `/report` to select or create a worktree report and attach it
to a draft. Reports appear in the dashboard and remain available across restarts.

[Report workflow and storage](docs/reports.md)

### Worktree references

Use `:Aero reference` to collect files and folders for a worktree, then `/reference`
to attach them to an ACP draft. Browse and manage stored references from the
dashboard or companion, with copy/cut staging for importing host files.

[Reference finder, storage, and companion access](docs/references.md)

### Persistent sessions and recovery

Aero saves workspace and session registrations, conversation history, terminal
scrollback, and each worktree's last code path and cursor. Reopen saved sessions to
resume work or read their history. Unsaved code contents are not saved across restarts.

[Session persistence and recovery](docs/persistence.md)

### Markdown Kanban boards

Track tasks on repository-wide boards backed by ordinary Markdown files with YAML
metadata. Use `:Aero board new` to create a board, edit tickets with native Vim
motions, and save all columns together with `:w`.

[Kanban workflow, keys, and file format](docs/kanban.md)

### Task-agent integration (opt-in)

Assign saved tickets to ACP sessions with `gw`. Aero registers its task MCP server
and drafts the assignment; revision-checked tools preserve conflicting user drafts.
Available on macOS and Linux with the `aero-mcp` executable.

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

Monitor ACP sessions, send follow-ups, answer permissions, and manage worktree
references from a phone browser. On your macOS/Linux Neovim host, run
`:Aero companion install`, then `:Aero companion start` to show the URL and pairing
code. Release binaries embed the web UI; the host and Neovim must remain running.

[Companion installation, pairing, and remote access](docs/companion.md)

## Development and releases

See the [architecture and reading guide](docs/architecture.md) for state ownership,
feature walkthroughs, and focused test commands. Use `make build-all` to build the
host tools, `make check-all` to verify them, and `make release` to package binaries.

[Host-tool requirements and publishing instructions](docs/releasing.md)

## License

Licensed under the [MIT License](LICENSE).

## Middle-panel reading tabs

Within each worktree, the middle panel has independent **Source**, **Exported logs**,
**References**, and **Reports** reading slots. Opening a report, exported log, or
reference from the dashboard selects its slot without replacing the source buffer.
Each slot keeps its buffer and reading position when switching.

To open a source file, select a worktree in the sidebar and press `e`. This opens
the worktree root in the **Source** slot using Oil when installed, or Neovim's
directory browser otherwise. Select a file there to read or edit it. Pressing `e`
on a report or exported log still opens that document in its own slot.
Use Ctrl-Enter or Ctrl-click on a worktree to resume its last source buffer instead
of reopening the root directory.

Click a slot in the middle panel's window bar, or use:

```vim
:Aero middle source
:Aero middle exports
:Aero middle references
:Aero middle reports
```

Click the `tabs ⇄` / `panes ⇄` control, or run `:Aero middle` to toggle the display.
`:Aero middle panes` shows opened slots in stacked middle-panel splits;
`:Aero middle tabs` returns to one reading window. Buffers, including unsaved edits,
are retained in either mode. In panes mode, use normal window navigation (`<C-w>j`
and `<C-w>k`) to move between readers. These controls do not create Neovim tabpages.
