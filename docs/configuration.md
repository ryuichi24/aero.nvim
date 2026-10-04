# Configuration reference

Customize agent commands, layout, mappings, storage, and appearance with `setup()`.

[Back to README](../README.md)

Only specify options you want to change. The complete defaults below match
`lua/aero/config.lua` and can be copied into your Neovim configuration.

## Task-agent integration

```lua
require("aero").setup({
  tasks = {
    agent = {
      enabled = false,
      executable = false, -- use the version-matched installed binary; or an absolute custom path
      adapters = { "opencode-acp", "claude-agent-acp", "codex-acp" },
      -- prompt may override the assignment instructions independently of reports.prompt
    },
    keymaps = { work = "gw" },
  },
})
```

See [agent task integration](agent-tasks.md) for builds, version-matched installation,
draft conflicts, supported transport, and runtime binding lifetime.

## Core defaults

Nested options are merged with defaults. Agent definitions are replaced wholesale;
`tasks.states` and `tasks.terminal_states` replace their default lists. Optional
settings without defaults are listed after this block.

```lua
require("aero").setup({
  agents = {
    claude = { cmd = { "claude" }, resume = { "claude", "--continue" }, key = "c" },
    codex = { cmd = { "codex" }, resume = { "codex", "resume", "--last" }, key = "x" },
    opencode = { cmd = { "opencode" }, resume = { "opencode", "--continue" }, key = "o" },
    ["claude-agent-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/claude-agent-acp" }, key = "C" },
    ["codex-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/codex-acp" }, key = "X" },
    ["opencode-acp"] = { type = "acp", cmd = { "opencode", "acp" }, key = "O" },
  },
  worktree_path = function(ws, branch)
    return vim.fs.joinpath(vim.fs.dirname(ws.root), vim.fs.basename(ws.root) .. ".worktrees", (branch:gsub("/", "-")))
  end,
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
  input = { adapter = "auto", select_default = true }, -- auto | dressing | snacks | vim_ui | function
  persist_buffers = true,
  state_file = vim.fn.stdpath("data") .. "/Aero/state.json",
  events = {}, -- event name -> function or list of functions; "*" observes all events
  layout = { min_code_width = 20 }, -- false disables automatic side-column rebalancing
  acp = {
    max_tool_lines = 20, -- truncate tool output in transcripts
    prompt_height = 25,
    decorations = true, -- native transcript cards, colors, and visual borders
    show_usage = true, -- agent-reported tokens, context usage, and cumulative fees
  },
  reports = {
    directory = "data", -- data | worktree | custom root | function(worktree, workspace_root)
    prompt = "Report file: {path}\nRead this Markdown report for context and write or update the report at this path with your findings.",
  },
  tasks = {
    directory = "data", -- data | worktree | custom root | function(workspace_root)
    yq = vim.env.AERO_TASKS_YQ or "yq",
    states = { "backlog", "todo", "in progress", "review", "test", "done" },
    terminal_states = { "done" },
    estimate_unit = "points",
    column_width = 32,
    agent = {
      enabled = false, -- opt in to task tools for ACP sessions
      executable = false, -- installed binary; or an absolute custom executable path
      adapters = { "opencode-acp", "claude-agent-acp", "codex-acp" }, -- allowed names from the agents table
      prompt = "Read the ticket through Aero's task tools and implement its requirements. Record progress and verification results with aero_update_ticket_body. Discover current board states before explicitly moving the ticket with aero_move_ticket. Do not write the task documents directly.",
    },
    keymaps = {
      open = "<CR>", source = "e", new = "ga", move = "m", work = "gw",
      rename = "N", remove = "gd", delete = "gD", metadata = "gi", states = "gs",
      refresh = "R", previous = "[s", next = "]s", up = false, down = false,
      earlier = "gK", later = "gJ", recover = "go", archive = "gA", close = "q", help = "g?",
    },
  },
  keymaps = { -- dashboard mappings; false disables an entry
    open = "<CR>", expand = "l", collapse = "h", toggle = "<Tab>",
    open_vsplit = "<C-v>", open_split = "<C-x>", open_tab = "<C-t>",
    add = "a", add_workspace = "A", delete = "d", stop = "s", restart = "r",
    rename = "N", refresh = "R", pull = "P", cd = ".", edit = "e",
    open_board_markdown = "I", edit_enter = "<C-CR>", edit_mouse = "<C-LeftMouse>",
    terminal = "t", next_workspace = "]]", prev_workspace = "[[", close = "q", help = "g?",
  },
  icons = {
    expanded = "▾", collapsed = "▸", busy = "◐", idle = "●",
    waiting = "?", exited = "✗", stopped = "○",
  },
})
```

See [layout](layout.md), [agents](agents.md), [reports](reports.md), [Kanban](kanban.md),
and [persistence](persistence.md) for behavior and storage options.

### Task options

- `tasks.directory`: `"data"` stores boards and tickets under Aero's workspace-scoped
  data directory; `"worktree"` uses the main checkout's `.aero/tasks`. A custom
  storage root or a function `(workspace_root)` returning a directory is also supported; see
  [Kanban storage](kanban.md).
- `tasks.yq`: executable path/name for Mike Farah's Go-based `yq` v4. Defaults to
  `AERO_TASKS_YQ` when set, otherwise `"yq"`.
- `tasks.states`: initial ordered states for new boards.
- `tasks.terminal_states`: states excluded from overdue indicators.
- `tasks.estimate_unit`: label displayed beside ticket estimates.
- `tasks.column_width`: minimum board column width; hidden states remain reachable
  with the previous/next state mappings.
- `tasks.agent.enabled`: enables task assignment and task-tool attachment to ACP
  sessions, including the local `/new-ticket` command.
- `tasks.agent.executable`: `false` selects the version-matched installed MCP
  binary. Set an absolute path for a custom build or an unpublished development
  revision. Install published binaries with `:Aero tasks install`.
- `tasks.agent.adapters`: names of configured ACP agents allowed to use task tools.
  Those agents must support the required ACP session capabilities; adding a name
  does not install or configure its provider.
- `tasks.agent.prompt`: instructions appended to the draft when assigning a ticket;
  independent of `reports.prompt`.
- `tasks.keymaps`: board mappings; set an individual entry to `false` to disable it.
  `work` assigns a ticket, while `recover` opens removed-ticket recovery.

### Optional settings without defaults

Agent definitions also accept `type = "terminal"` (the implicit default) and
`env = { NAME = "value" }`. See [agents and worktree paths](#agents-and-worktree-paths)
for command functions and replacement behavior.

`acp.resize_keys` overrides the full resize key chords in ACP prompt buffers.
Omitted directions inherit the shared shortcuts; individual directions or the
whole setting can be `false` to disable them:

```lua
require("aero").setup({
  acp = {
    resize_keys = {
      grow = "<C-w>k", shrink = "<C-w>j", narrow = "<C-w>h", widen = "<C-w>l",
    },
  },
})
```

The legacy top-level `resize_keys` accepts the same full-chord table or `false`
for all Aero panes. Prefer `resize.prefix` and `resize.keys` for shared mappings.
ACP-specific overrides are applied after the shared and legacy mappings.

`reports.directory` accepts `"data"`, `"worktree"`, a custom storage root, or a
function `(worktree, workspace_root)` returning an exact directory. In
`reports.prompt`, `{path}` expands to the JSON-quoted absolute report path.
See [reports](reports.md) for examples and [lifecycle hooks](integrations.md#events)
for every supported `events` name and payload.

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
    ["claude-agent-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/claude-agent-acp" }, key = "C" },
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
    open_board_markdown = "I",
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
      open = "<CR>", source = "e", new = "ga", move = "m", work = "gw", rename = "N",
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
