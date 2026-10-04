# Configuration reference

Customize agent commands, layout, mappings, storage, and appearance with `setup()`.

[Back to README](../README.md)

Only specify options you want to change. Defaults below match `lua/aero/config.lua`.

## Core defaults

```lua
require("aero").setup({
  dashboard = { position = "left", width = 40 }, -- left | right | current
  panel = { position = "right", width = 80 }, -- left | right; false uses last window
  worktree_tabs = true,
  terminal = { height = 12, cmd = nil }, -- nil uses { vim.o.shell }
  idle_ms = 1500, -- terminal output inactivity before idle
  notify_idle = true, -- notify when hidden sessions become idle
  start_insert = true,
  animation = true,
  fullscreen_key = "gF", -- false disables
  quote_key = "<leader>aq", -- false disables
  resize = { -- false disables
    prefix = "<C-w>",
    keys = { grow = "k", shrink = "j", narrow = "h", widen = "l" },
  },
  persist_sessions = true,
  prompt_session_name = true, -- ask for a name with `a` or agent shortcuts; false uses automatic names
  input = { adapter = "auto", select_default = true },
  persist_buffers = true,
  state_file = vim.fn.stdpath("data") .. "/Aero/state.json",
  events = {},
  acp = { max_tool_lines = 20, prompt_height = 25, decorations = true, show_usage = true },
  reports = {
    directory = "data",
    prompt = "Report file: {path}\nRead this Markdown report for context and write or update the report at this path with your findings.",
  },
  tasks = {
    directory = "data",
    yq = vim.env.AERO_TASKS_YQ or "yq",
    states = { "backlog", "todo", "in progress", "review", "test", "done" },
    terminal_states = { "done" },
    estimate_unit = "points",
    column_width = 32,
  },
})
```

See [layout](layout.md), [agents](agents.md), [reports](reports.md), [Kanban](kanban.md),
and [persistence](persistence.md) for behavior and storage options.

## Session-name input adapters

Session creation and renaming use your existing `vim.ui.input`. With the default
`input = { adapter = "auto", select_default = true }`, Aero recognizes Dressing
and Snacks input buffers and selects the default name in Select mode: typing
replaces it, and Enter keeps it. No global input-plugin configuration is changed.
The built-in command-line prompt and other providers retain their usual behavior.

Set `adapter` to `"dressing"` or `"snacks"` to restrict selection to that provider,
or `"vim_ui"` to use unmodified `vim.ui.input`. Set `select_default = false` to
disable selection. A custom adapter can implement another input UI:

```lua
require("aero").setup({
  input = {
    adapter = function(opts, callback)
      -- opts includes prompt, default, and select_default.
      -- Call callback(name) on confirmation, or callback(nil) on cancellation.
      my_input_ui(opts, callback)
    end,
  },
})
```

## Agents and worktree paths

```lua
require("aero").setup({
  agents = {
    claude = { cmd = { "claude" }, resume = { "claude", "--continue" }, key = "c" },
    codex = { cmd = { "codex" }, resume = { "codex", "resume", "--last" }, key = "x" },
    opencode = { cmd = { "opencode" }, resume = { "opencode", "--continue" }, key = "o" },
    ["claude-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/claude-agent-acp" }, key = "C" },
    ["codex-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/codex-acp" }, key = "X" },
    ["opencode-acp"] = { type = "acp", cmd = { "opencode", "acp" }, key = "O" },
  },
  worktree_path = function(ws, branch)
    return vim.fs.joinpath(vim.fs.dirname(ws.root), vim.fs.basename(ws.root) .. ".worktrees", (branch:gsub("/", "-")))
  end,
})
```

Add custom agents or set an entry to `false` to remove a default. Each supplied agent
definition replaces its default wholesale. `type` defaults to terminal; `cmd` and
terminal `resume` accept argument lists or functions receiving a session table.
`env` supplies environment variables. `key` sets its dashboard shortcut.

## Dashboard mappings

```lua
require("aero").setup({
  keymaps = {
    open = "<CR>", expand = "l", collapse = "h", toggle = "<Tab>",
    open_vsplit = "<C-v>", open_split = "<C-x>", open_tab = "<C-t>",
    add = "a", add_workspace = "A", delete = "d", stop = "s", restart = "r",
    rename = "N", refresh = "R", pull = "P", cd = ".", edit = "e",
    edit_enter = "<C-CR>", edit_mouse = "<C-LeftMouse>", terminal = "t",
    next_workspace = "]]", prev_workspace = "[[", close = "q", help = "g?",
  },
})
```

Set entries to `false` to disable them. See [dashboard actions](workspaces.md#dashboard-keys).
Kanban mappings are separate under `tasks.keymaps`:

```lua
require("aero").setup({
  tasks = {
    keymaps = {
      open = "<CR>", source = "e", new = "ga", move = "m", rename = "N",
      remove = "gd", delete = "gD", metadata = "gi", states = "gs", refresh = "R",
      previous = "[s", next = "]s", up = false, down = false,
      earlier = "gK", later = "gJ", recover = "go", archive = "gA", close = "q", help = "g?",
    },
  },
})
```

## Icons and highlights

```lua
require("aero").setup({
  icons = {
    expanded = "▾", collapsed = "▸", busy = "◐", idle = "●",
    waiting = "?", exited = "✗", stopped = "○",
  },
})
```

Dashboard groups: `AeroWorkspace`, `AeroWorktree`, `AeroMain`, `AeroBusy`, `AeroIdle`,
`AeroWaiting`, `AeroExited`, `AeroStopped`, `AeroDim`, `AeroTitle`.

Transcript groups: `AeroChatUser`, `AeroChatAgent`, `AeroChatThinking`, `AeroChatTool`,
`AeroChatCommand`, `AeroChatMeta`, `AeroChatError`, `AeroChatSuccess`, `AeroChatPending`,
`AeroChatBorder`, `AeroChatHeader`.

All are default links to colorscheme groups. Override with `vim.api.nvim_set_hl()`.
Run `:checkhealth aero` to check Git, agent executables, and the Kanban YAML dependency.

## Local development

Use a checkout directly on the runtimepath to see edits after restarting Neovim:

```sh
nvim --cmd 'set rtp^=/path/to/aero.nvim'
NVIM_APPNAME=Aero-dev nvim -u NONE --cmd 'set rtp^=/path/to/aero.nvim'
```

`--cmd` runs before plugin loading, so `:Aero` works without `setup()`.
Alternatively use lazy.nvim `{ dir = "/path/to/aero.nvim", opts = {} }` or prepend
the checkout in your config:

```lua
vim.opt.rtp:prepend(vim.fn.expand("/path/to/aero.nvim"))
require("aero").setup({})
```

`vim.pack.add` clones the repository, so its copy only updates after committing and
running `vim.pack.update()`. For published installs, pin with
`vim.pack.add({ { src = "https://github.com/ryuichi24/aero.nvim", version = "<branch-or-tag>" } })`.
