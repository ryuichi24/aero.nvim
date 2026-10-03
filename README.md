# aero.nvim

Manage **workspaces → git worktrees → AI agent sessions** (OpenCode, Claude Code, Codex, …) from Neovim,
with everything as plain Vim buffers you navigate with normal motions.

```
 aero.nvim  g? for help

 ▾ api-server ~/dev/api-server
   ▾ main (main)
     ● claude            idle
     ◐ claude-acp        busy
   ▸ feat/auth api-server-feat-auth ?1 ◐1
   ▾ fix/timeout
     ✗ codex             exited
 ▸ web ~/dev/web
```

- **Workspace**: a git repository (its main worktree). Saved across restarts.
- **Worktree**: read live from `git worktree list`. You can create and remove them from the dashboard.
- **Session**: an agent running in a worktree, of one of two kinds:
  - **terminal**: the agent CLI (`opencode`, `claude`, `codex`) in a `:terminal` buffer. Status (busy/idle) is
    guessed from terminal output activity.
  - **ACP**: the agent is driven over the [Agent Client Protocol](https://agentclientprotocol.com).

Sessions are remembered per worktree. After restarting Neovim, opening one attempts to resume it:
`claude --continue`, `codex resume --last`, or `opencode --continue` for terminal agents;
`session/load` for ACP agents.
Their ACP transcripts and terminal-agent scrollback are also saved, so you can browse the old
log after reopening a session. ACP history remains visible even if the agent cannot resume.

Requires Neovim 0.11+ and git.

### Features

- A dashboard for workspaces, Git worktrees, and terminal/ACP agent sessions.
- Quote visually selected code or agent logs into an agent's next prompt.
- An agent panel and a shell per worktree, with fullscreen available for every pane, including code.
- Persistent ACP transcripts, terminal-agent scrollback, and each worktree's last code buffer and cursor.
- Lifecycle hooks for integrations such as opening new worktrees in Oil.
- ACP conversation recovery by saved session ID.
- Workspace Kanban boards and tickets stored in ordinary Markdown, shared across worktrees.

### Contents

- [Install](#install)
- [Commands](#commands)
- [Dashboard](#dashboard)
- [Agent panel and fullscreen](#agent-panel)
- [Worktree tabs and remembered buffers](#worktree-tabs)
- [Worktree terminal](#worktree-terminal)
- [Dashboard keys](#dashboard-keys)
- [Quoting code and agent logs](#quoting-code-and-agent-logs)
- [ACP chat buffers](#acp-chat-buffers)
- [Persistence and recovery](#persistence-and-recovery)
- [Kanban task management](#kanban-task-management)
- [Lifecycle events and Oil](#lifecycle-events)
- [Configuration](#configuration)

## Install

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({ "https://github.com/you/Aero.nvim" })

require("aero").setup({})

vim.keymap.set("n", "<leader>aa", "<cmd>Aero<cr>", { desc = "Aero dashboard" })
vim.keymap.set("n", "<leader>ap", "<cmd>Aero pick<cr>", { desc = "Pick agent session" })
```

To pin a branch or tag, use `vim.pack.add({ { src = "https://github.com/you/Aero.nvim", version = "v0.1.0" } })`.
Update with `:lua vim.pack.update()`.

`setup()` is optional. Without it, `:Aero` uses the defaults.

### lazy.nvim

```lua
{
  "you/aero.nvim",
  cmd = "Aero",
  keys = {
    { "<leader>aa", "<cmd>Aero<cr>", desc = "Aero dashboard" },
    { "<leader>ap", "<cmd>Aero pick<cr>", desc = "Pick agent session" },
  },
  opts = {},
}
```

### From a local checkout

You don't need to publish anything to try the plugin. Put its folder on the `runtimepath`,
replacing `/path/to/Aero.nvim` with where your checkout is.

Example: the plugin is checked out at `~/dev/external/test` and you want to use it on a repo at
`~/dev/my-app`:

```sh
cd ~/dev/my-app                                    # any git repository
nvim --cmd 'set rtp^=~/dev/external/test'            # start Neovim with the plugin loaded
```

Then, inside Neovim:

```vim
:Aero add          " register the current repo as a workspace
:Aero              " open the dashboard; move to a worktree and press c to start Claude
```

To start a throwaway Neovim that also skips your own config and keeps Aero's state
separate:

```sh
NVIM_APPNAME=Aero-dev nvim -u NONE --cmd 'set rtp^=~/dev/external/test'
```

One-off try, without touching your config:

```sh
nvim --cmd 'set rtp^=/path/to/Aero.nvim'   # add -u NONE to skip your config too
```

`--cmd` runs before plugins load, so `:Aero` works right away and `setup()` isn't needed.

From your config, reading files straight from the checkout (restart Neovim to pick up edits):

```lua
vim.opt.rtp:prepend(vim.fn.expand("/path/to/Aero.nvim"))
require("aero").setup({})
```

With lazy.nvim, use `{ dir = "/path/to/Aero.nvim", opts = {} }`.

As a local package, loaded automatically on every start:

```sh
mkdir -p ~/.local/share/nvim/site/pack/dev/start
ln -s /path/to/Aero.nvim ~/.local/share/nvim/site/pack/dev/start/Aero.nvim
```

Don't use `vim.pack.add` for local development. It clones a git repo, so you'd be running a copy
that only changes after you commit and run `vim.pack.update()`.

Claude and Codex ACP agents use the official adapters and run them through `npx` by default:
[`@agentclientprotocol/claude-agent-acp`](https://www.npmjs.com/package/@agentclientprotocol/claude-agent-acp)
and [`@agentclientprotocol/codex-acp`](https://www.npmjs.com/package/@agentclientprotocol/codex-acp).
Install them globally (`npm i -g …`) and point `cmd` at the binary for faster startup.

### OpenCode

Install [OpenCode](https://opencode.ai/docs/) and make sure `opencode` is on Neovim's `PATH`.
OpenCode provides its own ACP server, so no separate adapter is needed.

| Agent          | Dashboard key | Command        | Resume                                       |
| -------------- | ------------- | -------------- | -------------------------------------------- |
| `opencode`     | `o`           | `opencode`     | `opencode --continue`                        |
| `opencode-acp` | `O`           | `opencode acp` | ACP `session/load` with the saved session ID |

Both are enabled by default. Focus a worktree in the dashboard and press `o` for the OpenCode
TUI or `O` for Aero's ACP transcript and prompt buffers. Like the other agents, they support
fullscreen, saved logs, lifecycle events, and worktree-specific sessions. ACP sessions also
support explicit recovery with `:Aero resume <session-id>`.

OpenCode uses its configured providers, models, and credentials. To customize the launch
command, replace the corresponding agent definition in `setup()`:

```lua
require("aero").setup({
  agents = {
    opencode = { cmd = { "opencode" }, resume = { "opencode", "--continue" }, key = "o" },
    ["opencode-acp"] = { type = "acp", cmd = { "opencode", "acp" }, key = "O" },
  },
})
```

## Commands

| Command             | Description                                                   |
| ------------------- | ------------------------------------------------------------- |
| `:Aero`             | toggle the dashboard                                          |
| `:Aero add [path]`  | add the git repo containing `path` (default: cwd)             |
| `:Aero pick`        | pick any session with `vim.ui.select`                         |
| `:Aero resume <id>` | reconnect the selected ACP session to a saved conversation ID |
| `:Aero panel`       | toggle the agent panel                                        |
| `:Aero fullscreen`  | toggle fullscreen for the focused pane                        |
| `:Aero prompt`      | jump to the panel session's prompt (or terminal)              |
| `:Aero cancel`      | cancel the selected ACP agent's turn and discard queued prompts |
| `:Aero usage`       | show reported token usage and fees for the selected agent     |
| `:Aero report`      | pick or create a worktree report and attach it to an agent draft |
| `:Aero board`       | pick/open a board in the current workspace                    |
| `:Aero board new`   | create a workspace board                                      |
| `:Aero ticket new`  | create a ticket in the selected state of the active board     |
| `:Aero ticket move` | move the selected ticket to any state of the active board     |
| `:'<,'>Aero quote`  | quote the selected lines into an agent's draft               |
| `:Aero term`        | toggle the worktree's shell below the code window             |
| `:Aero refresh`     | re-read worktrees                                             |
| `:Aero pull`        | pull the selected worktree's upstream (fast-forward only)     |

## Dashboard

`:Aero` (or `:Aero toggle`) shows or hides the dashboard in the current tab, even when
you are focused on code, a prompt, or a terminal. Use `:Aero open` to show and focus it
without hiding an already-visible dashboard, or `:Aero close` to hide it explicitly.

For a keyboard shortcut:

```lua
vim.keymap.set("n", "<leader>ad", "<cmd>Aero toggle<cr>", { desc = "Toggle Aero dashboard" })
vim.keymap.set("i", "<leader>ad", "<Esc><cmd>Aero toggle<cr>", { desc = "Toggle Aero dashboard" })
vim.keymap.set("t", "<leader>ad", "<C-\\><C-n><cmd>Aero toggle<cr>", { desc = "Toggle Aero dashboard" })
```

## Agent panel

Sessions open in a fixed-width panel at the right edge of the tab. The rest of the tab stays
free for code, so you can browse and edit while the agent works. Files the agent edits update
live in the buffers you have open. The panel's title bar shows the session, its worktree and
what it's doing right now.

While an ACP agent works, a spinner and its current activity show in the transcript's last line,
the panel title bar and the dashboard: `thinking`, `writing`, the title of the tool it's running
(e.g. `Read src/auth.lua`), or `waiting for your permission`, plus the turn's elapsed time.
Running tool calls in the transcript spin until they finish. Terminal agents get the spinner
while they produce output. Set `animation = false` for static icons.

```
 Aero        │ src/auth/limiter.lua          │ claude-acp · feat-auth ◐ busy
 ▾ api-server │                               │ ## You
   ▾ feat/auth│  (your code)                  │ add rate limiting
     ◐ claude │                               │ ## Claude
              │                               ├───────────────────────
              │                               │ prompt
```

- `:Aero panel` hides and shows the panel. It remembers the last session shown in each tab.
- `:Aero prompt` jumps into the prompt (or terminal) from anywhere, opening the panel if needed.
- `:Aero cancel` stops the focused or dashboard-selected ACP agent, or the current tab's panel
  session (even when hidden). You can also send `/cancel` from its prompt or press `<C-c>` in
  its transcript or prompt. Cancellation discards queued prompts and pending permission requests;
  the conversation stays open. Send a new prompt to continue once the agent acknowledges cancellation.
- `e` in the dashboard and other file opens never land in the panel.
- `<C-v>` / `<C-x>` / `<C-t>` still open a session in a split or tab of their own.

```lua
vim.keymap.set("n", "<leader>ac", "<cmd>Aero panel<cr>", { desc = "Toggle agent panel" })
vim.keymap.set("n", "<leader>ai", "<cmd>Aero prompt<cr>", { desc = "Prompt the agent" })
```

Set `panel = false` to open sessions in the last used window instead.

### Resizing all panes

Drag the vertical panel border to change its width, or the horizontal border above an ACP
prompt to change its height (`:set mouse=a` enables mouse support). You can also resize from
normal mode in the dashboard, agent transcript, prompt, terminal agent, worktree shell,
or the code pane in an Aero tab:

| Key / command              | Action                                      |
| -------------------------- | ------------------------------------------- |
| `<C-w>+` / `<C-w>-`        | increase / decrease the focused pane's height |
| `<C-w>j` / `<C-w>k`        | shrink / grow the focused pane by one line |
| `<C-w>h` / `<C-w>l`        | narrow / widen the focused pane by one column |
| `<C-w>>` / `<C-w><`        | increase / decrease the focused pane's width  |
| `:resize 12`               | set the focused prompt to 12 lines          |
| `:vertical resize 80`      | set the focused agent panel to 80 columns   |

In a prompt or code buffer, press `<Esc>` to leave insert mode; in a terminal, use
`<C-\><C-n>` to enter normal mode. Counts work with native resize commands too,
for example `5<C-w>+` adds five lines.

`<C-w>j` means press Ctrl-w, then `j`; `<C-w>k` means press Ctrl-w, then `k`.
Once resizing starts, keep pressing `j` to shrink or `k` to grow: `<C-w>kkk` adds
three lines. Use `<C-w>h` to narrow the pane or `<C-w>l` to widen it; `<C-w>lll` adds
three columns. You can mix `h`, `j`, `k`, and `l` after starting a resize.
Any other key (including `<Esc>`) or leaving the pane ends resize mode and restores
normal `h`/`j`/`k`/`l` movement.
These four shortcuts replace directional window navigation in Aero panes; use `<C-w>w`
or `<C-w>p` to switch windows. Code buffers outside Aero tabs keep their normal Ctrl-w
behavior. Ctrl-s in prompts sends immediately in normal and insert mode.
Customize or disable the resize keys:

```lua
require("aero").setup({
  resize = {
    prefix = "<C-w>", -- e.g. "<leader>r" or "g"
    keys = { grow = "k", shrink = "j", narrow = "h", widen = "l" },
  }, -- or false to disable everywhere
})
```

Both the prefix and repeat keys are configurable. For example, `prefix = "g"` with
`grow = "u"` makes `guuu` grow the pane by three lines. Once resizing starts, repeat
the configured direction keys without pressing the prefix again.

The previous `resize_keys` table of full shortcuts is also supported, and
`acp.resize_keys` can override full shortcuts for prompt buffers specifically.

Aero remembers dashboard and agent-panel widths per tab, prompt height per session in
each tab, and shell height per worktree in each tab for the current Neovim instance.
Sizes survive hiding and reopening these panes, and sending a prompt. `dashboard.width`,
`panel.width`, `terminal.height`, and `acp.prompt_height` are initial sizes.
Fullscreen starts with the current prompt height; resizing there does not change the
original tab's layout.

#### Default prompt size

The ACP prompt defaults to **8 lines**, and shares the agent panel's default width of
**70 columns**. Configure both initial dimensions in `setup()`:

```lua
require("aero").setup({
  acp = { prompt_height = 12 }, -- prompt height in lines; default: 8
  panel = { width = 80 },      -- shared transcript/prompt width in columns; default: 70
})
```

These defaults apply before a pane has been resized. Afterwards, the remembered size
takes precedence for that session/tab until Neovim exits.

When a terminal agent exits, the panel returns to normal mode and keeps its scrollback.
Use regular window navigation, such as `<C-w>w`, to leave the panel; no terminal escape is
needed after exit.

### Fullscreen panels

Focus the middle code pane, dashboard, an agent transcript/prompt, or the worktree terminal
and press **`gF`** in normal mode (or run **`:Aero fullscreen`**). The pane fills a temporary tab using the same
buffers and running session. Toggle again to return to the original tab, split sizes and focus.
Closing the temporary tab also exits fullscreen.

For ACP agents, an open prompt is shown below the fullscreen transcript, and `i` or
`:Aero prompt` can open it while fullscreen. Unsent drafts are kept. In a terminal, first
press `<C-\><C-n>` to enter normal mode, then `gF`.

Set `fullscreen_key = false` to disable the mapping, or change it to another key.
For a shortcut usable from insert/terminal mode:

```lua
vim.keymap.set("n", "<leader>af", "<cmd>Aero fullscreen<cr>", { desc = "Fullscreen Aero panel" })
vim.keymap.set("i", "<C-g>", "<Esc><cmd>Aero fullscreen<cr>", { desc = "Fullscreen Aero panel" })
vim.keymap.set("t", "<C-g>", "<C-\\><C-n><cmd>Aero fullscreen<cr>", { desc = "Fullscreen Aero panel" })
```

## Worktree tabs

Each worktree gets its own tab whose working directory (`:tcd`) is the worktree. Opening a
session, `:Aero pick` or `e` switches to that worktree's tab, so the code windows, file
pickers, `:e`, grep and LSP all act on that checkout. Each tab keeps its own windows and
buffers, and its own agent panel.

- A new worktree tab restores its last code buffer in the middle window and brings the dashboard along.
- A tab you already had open inside a worktree (for example the one you started Neovim in) is
  reused for that worktree instead of opening a new one.
- Removing a worktree with `d` closes its tab.

Set `worktree_tabs = false` to keep everything in the current tab.

Aero remembers the last file or directory shown in each worktree's code pane, including
Oil directories, and its cursor position. Returning with `e`, opening an agent's worktree,
or calling `open_worktree(path)` restores that buffer. Live buffers are reused within the
same Neovim instance, preserving unsaved edits; across restarts Aero reopens the saved path.
If there is no saved buffer or the file has been removed, the worktree directory opens instead.
The dashboard, agent transcripts/prompts, and terminal buffers do not replace this code-buffer
selection. This also works with `worktree_tabs = false`.

Buffer paths and cursor positions are saved in `state.json`, independently of agent-session
persistence. Set `persist_buffers = false` to keep this memory only within the current Neovim
instance. Buffer contents and unsaved edits are not written to Aero's state.

## Worktree terminal

`:Aero term` toggles a shell in a split at the bottom of the code window, started in the
current tab's worktree. `t` in the dashboard opens the terminal of the worktree under the
cursor. Each worktree has its own shell, and hiding it keeps it running. Files opened from the
dashboard never land in the terminal window.

```lua
vim.keymap.set("n", "<leader>at", "<cmd>Aero term<cr>", { desc = "Toggle worktree terminal" })
```

## Dashboard keys

| Key                     | Action                                                                                                     |
| ----------------------- | ---------------------------------------------------------------------------------------------------------- |
| `<CR>`                  | open session / toggle node                                                                                 |
| `l` / `h`               | expand (or step into) / collapse (or go to parent)                                                         |
| `<C-v>` `<C-x>` `<C-t>` | open session in vsplit / split / tab                                                                       |
| `a`                     | on a workspace: new worktree (branch prompt); on a worktree: start a new session of a chosen agent         |
| `c` / `x` / `C` / `X`   | open claude / codex / claude-acp / codex-acp on the worktree, reusing its existing session if there is one |
| `o` / `O`               | open opencode / opencode-acp on the worktree, reusing its existing session if there is one                 |
| `A`                     | add workspace                                                                                              |
| `d`                     | delete selected item: session / report (both with confirmation) / `git worktree remove` / forget workspace  |
| `s` / `r`               | stop / restart (resume) session                                                                            |
| `N`                     | rename selected agent session, report, or board                                                             |
| `.` / `e`               | `:tcd` to worktree / restore its last code buffer                                                          |
| `<C-LeftMouse>`          | open the clicked worktree in the code pane / restore its last code buffer                                 |
| `<C-CR>`                | open the selected worktree in the code pane / restore its last code buffer                                |
| `t`                     | open the worktree's terminal                                                                               |
| `P`                     | pull the worktree's configured upstream (fast-forward only)                                                |
| `]]` / `[[`             | next / previous workspace                                                                                  |
| `R` / `q` / `g?`        | refresh / close / help                                                                                     |
| `gF`                    | toggle fullscreen                                                                                          |

Ctrl-click a worktree name to enter its tab and focus its code pane without starting an
agent. This also works on workspace and session rows, opening their corresponding worktree.
Mouse support must be enabled in Neovim (`:set mouse=a`). Customize the shortcut with:

```lua
require("aero").setup({
  keymaps = {
    edit_mouse = "<C-LeftMouse>", -- e.g. "<S-LeftMouse>" or "<2-LeftMouse>"; false disables it
    edit_enter = "<C-CR>",       -- Ctrl-Enter on the selected row; customizable or false to disable
  },
})
```

### Pulling a worktree

Place the dashboard cursor on a worktree and run **`:Aero pull`** or press **`P`**.
Aero runs `git -C <worktree> pull --ff-only` asynchronously, using that checkout's
configured upstream. Workspace rows pull the main checkout; session rows pull their
worktree. The dashboard and unmodified open files refresh after a successful pull,
and Git's output or error is reported in a notification. Pulling does not switch tabs
or change the working directory. Repeated pulls of the same worktree are ignored
while a pull is already running.

Outside the dashboard, `:Aero pull` uses the focused agent's worktree, the current tab's
worktree, or the current working directory. The Lua API also accepts an explicit path:
`require("aero").pull(path)`.

Customize or disable the dashboard shortcut:

```lua
require("aero").setup({
  keymaps = { pull = "P" }, -- e.g. "gp"; false disables the key, not :Aero pull
})
```

The pull only fast-forwards: divergent branches, local changes that Git cannot preserve,
and missing upstreams are reported by Git rather than merged automatically.

## Quoting code and agent logs

Select text with `v`, `V`, or `<C-v>`, then press **`<leader>aq`** to quote it into
an agent's next prompt. This works in code buffers, ACP transcripts, and terminal-agent
scrollback. In a terminal, first use `<C-\><C-n>` to enter normal mode.
With Vim's default leader, the shortcut is `\`, then `a`, then `q`.

The quote includes its source and line range, with a fenced block preserving the selected
text. Code paths inside the target worktree are shown relative to that worktree. Selection
respects characterwise, linewise, blockwise, and exclusive Visual modes without changing
the source buffer or your yank registers.

- **From code:** quote to the session shown in the agent panel, or its last session if
  the panel is hidden. Otherwise, use the current worktree's session or choose one when
  there are several.
- **From an agent log:** quote back to that log's session, even if another session is
  currently shown in the panel.
- **ACP:** append to the existing prompt draft and focus it. Nothing is submitted;
  you can add a question or edit the quote before sending.
- **Terminal agents:** bracketed-paste the quote into the CLI input without adding a
  submit keystroke.

The shortcut is installed by `setup()` or when you first open Aero. Customize or disable it:

```lua
require("aero").setup({
  quote_key = "<leader>aq", -- e.g. "gq"; false disables the visual mapping
})
```

The Lua API is `require("aero").quote()` while a Visual selection is active. You can also
use `:'<,'>Aero quote` or an explicit range such as `:10,15Aero quote`; command ranges
quote complete lines. The visual shortcut preserves partial-line and block selections.

## ACP chat buffers

### Transcript layout

ACP logs use an OpenCode-inspired visual hierarchy, rendered with native Neovim
highlighting and virtual borders:

- **Messages:** separate user and agent headings, with normal Markdown for prose and code.
- **Thinking:** a labeled, muted section so reasoning is easy to distinguish from the answer.
- **Tool calls:** typed cards for Read, Edit, Search, Fetch, and other tools, with status icons,
  file locations, and separate output or diff sections.
- **Commands:** their own cards with shell input, working directory when available, and output.
- **Metadata:** consecutive model changes and session events share a compact Session card,
  rather than appearing as separate italic paragraphs. Earlier saved logs use this layout too.
- **Errors and permissions:** distinct highlighted sections; permission options remain selectable
  with `<CR>` or their number keys.

For example (borders are visual decorations, not text in the buffer):

```text
┌ Session
│ Model: OpenAI/GPT-6 Luna (openai/gpt-6-luna)
│ Model: OpenAI/GPT-6.1 Sol (openai/gpt-6.1-sol)
│ resumed session
└─

┌ Thinking
│ Check the existing tests before changing the implementation.
└─

┌ ✓ Command · completed
│ Run the tests
│ Input
│ $ npm test
│ Output
│ All tests passed.
└─
```

Tool output still respects `acp.max_tool_lines`, including an explicit count of omitted
lines. Streaming updates preserve the earlier transcript's view and decorations.
Virtual borders and shell `$` markers are excluded when you yank or quote text.
No external Markdown-rendering plugin is required. Disable the extra visual decoration with:

```lua
require("aero").setup({ acp = { decorations = false } })
```

Transcript buffer (read-only markdown):

| Key                        | Action                                               |
| -------------------------- | ---------------------------------------------------- |
| `i` `a` `o` `I` `A` `<CR>` | open the prompt buffer below                         |
| `<CR>` on an option        | answer the permission request with it                |
| `1`–`9`                    | answer with that option (while a request is pending) |
| `p`                        | go to the pending permission request                 |
| `<C-c>`                    | cancel the current turn (and a pending request)      |

Prompt buffer (regular markdown buffer; the draft is kept if you close it):

| Key            | Action                           |
| -------------- | -------------------------------- |
| `:w` / `<C-s>` | send                             |
| `<CR>`         | send (normal mode)               |
| `<C-x><C-o>`   | complete the agent's `/commands` |
| `q`            | close (normal mode)              |
| `<C-c>`        | cancel the current turn          |

### Session tokens and fees

Aero displays agent-reported usage in a **Usage card** at the end of the ACP transcript,
in the panel title bar, and alongside the session in the dashboard.
Compact summaries also include context usage as a percentage, for example
`3.0k/10.0k ctx (30.0%)`. The percentage is omitted when context capacity is zero.

Use **`:Aero usage`** while focused on an agent log/prompt or a dashboard session row
for the detailed report:

```text
Tokens (reported turns): 1,860
Reported turns: 2 · Input: 1,400 · Output: 340
Thinking: 60 · Cache read: 50 · Cache write: 10
Context: 3,000 / 10,000 tokens (30.0%)
Total fee (last reported): USD 0.02
```

- **Tokens:** accumulated from prompt-response usage reported by the agent, including
  reasoning/cache breakdowns when available. The agent's `totalTokens` is authoritative;
  if absent, Aero uses reported input plus output when both are available. These are
  tracked reported turns, not an estimate of unreported internal model calls or older
  conversation activity that Aero never received.
- **Context:** the latest reported context-window occupancy. It is separate from consumed
  tokens and can decrease after compaction.
- **Fee:** the agent's latest cumulative session cost, in the reported currency. Each
  update replaces the previous snapshot; repeated updates are never added together.
  Aero does not infer model prices or calculate fees from transcript text.

Availability depends on what the agent/version reports over ACP. Missing data is shown
as **not reported**, while an explicitly reported zero fee is shown as `USD 0.00`.
Metrics are saved with session history and restored across restarts. Resuming a session
keeps its tracked totals; starting a new conversation resets them. `:Aero usage` can also
read saved metrics for an unopened dashboard session without starting its agent.

To hide the automatic displays while continuing to track usage:

```lua
require("aero").setup({ acp = { show_usage = false } })
```

The Lua API `require("aero").usage()` shows the report and returns a copy of the available
`tokens`, `context`, and `cost` metrics (or `nil` if none have been reported).

### Changing the model

In an ACP prompt, enter **`/model`** and send it with `:w` or `<C-s>` to open a model picker.
The picker lists the models exposed by the agent and marks the current selection. The current
model is also shown in the agent panel's title bar.

You can select a model directly by its ID or an unambiguous display name:

```text
/model
/model provider/model-id
```

Use `<C-x><C-o>` to complete `/model` and the available IDs after `/model `. Aero handles this
command locally and calls the adapter's model-setting API; it does not send the command as
an AI prompt or create a new conversation. ACP configuration options are preferred, with
the older `session/set_model` API supported for agents that expose legacy model metadata.

If the agent is working, the command waits for the current turn to finish and runs before
later queued prompts. Cancelling the picker or a rejected model change leaves the current
model unchanged. Model metadata is refreshed when a session is loaded and when the agent
publishes configuration updates. An agent that does not expose model controls over ACP is
reported as unsupported.

For terminal agents, use the agent CLI's own model command while in terminal-input mode.

### Changing the session mode

In an ACP prompt, enter **`/mode`** and send it with `:w` or `<C-s>` to choose a session
mode, such as OpenCode's Build or Plan. The picker marks the current mode, which is also
shown in the agent panel's title bar. Available modes and their behavior are defined by
the agent.

You can switch directly using a mode ID or an unambiguous display name:

```text
/mode
/mode plan
/mode build
```

Use `<C-x><C-o>` to complete `/mode` and the IDs after `/mode `. Aero handles the command
locally, preserving the conversation. It prefers ACP session config options and falls back
to `session/set_mode` for agents exposing legacy session modes. Mode metadata is refreshed
on session load and agent updates, including automatic mode changes.

While the agent is working, mode changes wait for the current turn and run before later
queued prompts. Cancelling the picker or a rejected change leaves the current mode unchanged.
Agents without mode selection over ACP are reported as unsupported. For terminal agents,
use the agent CLI's own mode controls.

### Reports

Use **`:Aero report`** from an agent log/prompt, a worktree or session row in the sidebar,
or the worktree's code pane. A floating menu lists that worktree's Markdown reports, with
**`New +`** as the last item. Move with `j`/`k` or the arrow keys, press `<CR>` to select,
and use `<Esc>` or `q` to cancel. If multiple agents are available without a selected
session, Aero asks which one should receive the report.

In ACP prompts, typing **`/report`** and pressing Enter opens the same picker. Sending
`/report` with `:w` or `<C-s>` also works, and `<C-x><C-o>` completes the command.
Enter in other drafts continues to insert a newline.

Selecting a report appends its absolute path and a short instruction to read and update
it to the agent's existing draft. `New +` asks for a filename, adds `.md` if needed,
creates an empty file, and attaches it. Existing files are never overwritten when creating
a report. You can add your task to the draft before sending it; selecting a report does
not submit a prompt. Terminal agents receive the instruction as a bracketed paste.

Customize the inserted text with `reports.prompt`. Every `{path}` placeholder is replaced
with the JSON-quoted absolute report path; all other text is inserted literally. This applies
to both ACP and terminal agents. The default preserves the instruction above.

```lua
require("aero").setup({
  reports = {
    prompt = "Report file: {path}\nRead the report and update it with a concise summary of your findings.",
  },
})
```

For a custom keymap:

```lua
vim.keymap.set("n", "<leader>ar", "<cmd>Aero report<cr>", { desc = "Attach Aero report" })
vim.keymap.set("i", "<leader>ar", "<cmd>Aero report<cr>", { desc = "Attach Aero report" })
```

Reports also appear in an expandable **Reports** section beneath each worktree in the
sidebar. `<CR>` opens a report in the code pane; `<C-v>`, `<C-x>`, and `<C-t>` open it in
a split or tab. `New +` or `a` within the Reports section creates and opens an empty
report. Press `d` on a report to delete its file after confirmation; press `d` on a session
to delete that session independently after confirmation. Use `:Aero report` to attach a report to an agent. Refresh with `R` after external
file changes; writing Markdown files and agent activity also refresh the list.

#### Report storage

The default is:

```text
stdpath("data")/Aero/workspaces/<workspace>/<worktree>/reports/*.md
```

Workspace and worktree folder names use their directory basenames with short path hashes,
so repositories or worktrees with identical names keep separate reports. Reports are
discovered from the filesystem and remain available across Neovim restarts.

Set `reports.directory` to choose where reports are stored:

```lua
-- Default: Aero's data directory, scoped by workspace and worktree.
require("aero").setup({ reports = { directory = "data" } })

-- Store directly in <target worktree>/.aero/reports/*.md.
require("aero").setup({ reports = { directory = "worktree" } })

-- A custom absolute root retains the <workspace>/<worktree>/reports hierarchy.
require("aero").setup({ reports = { directory = "~/Documents/Aero-reports" } })

-- A relative directory is used directly inside each target worktree.
require("aero").setup({ reports = { directory = ".notes/reports" } })

-- A function returns an exact directory (relative paths resolve inside the worktree).
require("aero").setup({
  reports = {
    directory = function(worktree, workspace_root)
      return vim.fs.joinpath(worktree, ".aero", "reports")
    end,
  },
})
```

### Permission requests

Permission requests are listed in the transcript, with their options numbered:

```
┌ Permission requested
│ Edit limiter.lua
│
│   1. Allow once
│ ▸ 2. Always allow
│   3. Reject
│
│ <CR> or 1-3 to choose, <C-c> to cancel
└─
```

The transcript's cursor moves to the options when a request arrives. You're only moved into
the transcript if you're already in it, and otherwise you get a notification. `:Aero prompt`
(or opening the session) takes you to a pending request. Until you answer, the session shows
as `?` (waiting) in the dashboard.

The ACP client handles `fs/read_text_file` and `fs/write_text_file` itself. Reads come from loaded
buffers (so the agent sees unsaved changes), and writes to loaded buffers go through the buffer.
Terminal delegation (`terminal/*`) isn't offered yet, so agents run commands themselves.

## Persistence and recovery

### What is remembered

State is saved to `stdpath("data")/Aero/state.json`, or the configured `state_file`. Several
Neovim instances can share it: each change is merged into the latest saved state, and the
file is replaced atomically. Session logs are stored separately in `<state_file>.history/`.

| Data                      | Restored behavior                                                                                           |
| ------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Workspaces                | Registered repositories and their expanded/collapsed state.                                                 |
| Sessions                  | Session names and agent choices per worktree, plus saved ACP conversation IDs. Processes start when opened. |
| ACP transcripts           | Messages, thoughts, tool calls, plans, permission outcomes, and the session ID.                             |
| Terminal-agent scrollback | Saved text appears above the new agent output, within the terminal buffer's scrollback limit.               |
| Code buffers              | Each worktree's last file/directory/Oil buffer and cursor position.                                         |

Log snapshots are written during output and flushed when Neovim exits normally. Historical
terminal colors and cursor state are not retained. Deleting a session removes its saved log.
Code-buffer contents and unsaved edits are not saved by Aero; live buffers are reused within
the current Neovim instance, and saved paths are reopened across restarts.

`persist_sessions = false` disables session and log persistence. `persist_buffers = false`
independently disables cross-restart code-buffer persistence. To keep development state
separate, use `NVIM_APPNAME=Aero-dev` or configure a different `state_file`.

### Retrying an ACP session

Restoring the visible transcript and resuming the agent's conversation are separate operations.
Aero can show its saved log even when the adapter cannot load the original conversation.
The agent's own conversation storage must remain available for a true resume.

If an ACP `session/load` request fails, Aero keeps the saved conversation ID and transcript
and stops the failed backend instead of automatically creating a replacement conversation.
The transcript shows the adapter's error message, code, and additional error data, plus
available adapter stderr. Select the session in the dashboard and press **`r`** to retry loading the same
conversation. Prompts queued before the failure remain queued for a retry in the same Neovim
instance. Use `a` on the worktree to create a separate fresh session when desired.

### Reconnecting to a known conversation

To reconnect an Aero session whose saved ID points at the wrong conversation:

1. Find the original conversation ID in the agent's saved sessions.
2. Select the ACP session in Aero's dashboard, or focus its transcript/prompt.
3. Run:

   ```vim
   :Aero resume <session-id>
   ```

The Lua API is `require("aero").resume(session_id)`. The replacement ID is saved only after the adapter
successfully loads it. The chosen conversation replays its own history; cached error messages
do not suppress that replay, and a cache belonging to a different ID is replaced on success.
If recovery fails, the previous saved ID and transcript remain available.

### Codex: “no rollout found for thread id”

A rollout is Codex's saved conversation file. This error means the current Codex process cannot
find a rollout for the ID Aero requested. Codex writes a rollout after the first user message,
so a session created without a prompt may have nothing to restore after restarting.

If the session previously had a conversation, check the Codex home directory used by the
adapter (`CODEX_HOME`, normally `~/.codex`). Saved conversations are under `sessions/`, with
filenames like `rollout-<timestamp>-<session-id>.jsonl`; the first record contains the session
ID and working directory. Archived conversations may be under `archived_sessions/`.

A previous fallback to a new session may have left Aero pointing at an unused replacement
ID while the original rollout still exists under a different ID. Locate the original
conversation for the worktree and reconnect with `:Aero resume <session-id>`. Retrying the
missing ID with `r` cannot recreate its rollout, and the visible Aero log alone is not the
agent's resumable conversation state.

## Kanban task management

Every workspace has a **Boards** section in the sidebar, independent of its worktrees
and agent sessions. Press `<CR>` on a board to open its Kanban view in a dedicated full-width tab;
`e` opens the source Markdown. `a` on a board/Boards row or `<CR>` on its **New +** row
creates a board. `N` renames a board without changing its folder. `d` explicitly confirms
permanent deletion of the entire board folder **including its tickets**.

### YAML dependency

Task management uses **[Mike Farah's Go-based `yq` v4](https://github.com/mikefarah/yq)**
(MIT license) for YAML parsing and round-trip editing. No Python runtime or helper is needed.
Duplicate keys and unsupported YAML tags are rejected, and metadata types and dates are
validated before writes. Use this Go implementation; the Python-based `yq` package and
older `yq` versions are not compatible.

Install it with Homebrew, or use a binary from the project's releases:

```sh
brew install yq
yq --version
```

```lua
require("aero").setup({
  tasks = {
    yq = "yq", -- or an absolute path to Mike Farah's yq v4 executable
    directory = "data",
    states = { "backlog", "todo", "in progress", "review", "test", "done" },
    terminal_states = { "done" },
    estimate_unit = "points",
  },
})
```

The executable defaults to `yq` (or `AERO_TASKS_YQ` when set).
`:checkhealth aero` checks the implementation and version. Configured state lists are replaced
wholesale and apply to new boards; existing boards derive their states from their files.
`terminal_states` names suppress overdue indicators. A due date before the current UTC
date is overdue unless the ticket is in one of these states. Estimates use the configured
workspace-wide unit, **points** by default.

### Board view and keys

Each state is a separate **editable buffer**, displayed in a column window. Each ticket
occupies one physical line (`ticket-id  title`); metadata is shown as virtual text.
Column headers show the board, state, counts, and archive/stale status; `g?` shows the
board summary, tags, mappings, and source diagnostics. Ticket IDs are concealed, like Oil's
entry identifiers, so rows display only their titles. Full IDs remain in the buffer and
travel with cut/paste; use `:setlocal conceallevel=0` to inspect them. Titles are retained
in full; use normal horizontal scrolling when a column is narrow.

Each board has its own reusable tab, giving its columns the full editor width without the
dashboard or agent panel. Opening the same board again focuses its existing tab. `q` closes
the board tab and returns to the originating tab; save or discard pending board edits first.
Closing the tab retains its state buffers, so reopening restores the board session.

Press `<CR>` on a ticket to edit its real Markdown file in a centered floating window,
with the board columns visible underneath. Normal `:w` saves, `:wq` saves and closes,
and `:q` closes the editor. Unsaved changes follow normal Vim buffer behavior: with
`hidden` enabled, closing keeps the modified buffer and reopening restores its draft;
otherwise Vim asks you to save first. Use `:e!` to explicitly reload and discard edits.
The ticket float recenters/resizes with the
editor. `e` continues to open the source board in a separate code split.

**Move tickets like editing files in Oil:** `dd` cuts a row, `<C-w>h` / `<C-w>l` changes
column, and `p` / `P` pastes. Visual cut/paste moves multiple tickets. **`:w` in any column
saves all columns together**, including hidden ones, in one board Markdown update.
Ticket files are not moved or changed. `m` and reorder shortcuts also stage changes until `:w`.

Missing, duplicate, unknown, or edited ticket rows reject the whole save and retain your draft.
Do not edit IDs or titles here; use `N` to rename. Cutting without pasting is not deletion;
use `gd` / `gD` for explicit removal. These actions, ticket creation, and metadata/state edits
require a clean draft first.

Undo/redo is **column-local**: a cross-column move edits two buffers, so undo in only one
may temporarily leave a missing or duplicate ticket. After a save, undo produces a new draft;
persist the reversed placement with another `:w`. External source changes never replace a
modified draft; stale saves fail. Use `e` to compare source or `R` to explicitly discard all
pending column edits and reload.

`tasks.column_width` (default `32`) controls how many columns are displayed. Screen/window
resizes automatically rebalance columns and reveal or hide states to fit the available width,
including when moving to another monitor. Inactive board tabs adapt when entered again.
`[s` / `]s` reveal off-screen states while retaining their buffers.
Closing a column window keeps its edits; a wiped state buffer blocks saving until reloaded.
Tabs opening the same board share the editing session. Resizing never replaces draft lines.

| Key | Action |
| --- | --- |
| `[s` / `]s` | previous / next state, including hidden columns |
| `h` / `j` / `k` / `l`, `dd`, `p`, `u`, `<C-r>` | ordinary Vim editing and column-local undo/redo |
| `<CR>` | edit the selected ticket Markdown in a floating window |
| `e` | edit the source board Markdown |
| `ga` | create a ticket in the selected state |
| `m` | stage movement to a chosen state; save with `:w` |
| `gK` / `gJ` | stage movement earlier / later within its state |
| `N` | rename the selected ticket, or the board on an empty row |
| `gi` | edit ticket/board metadata; values are entered as JSON |
| `gs` | add, rename, reorder, or remove a state; populated states require a destination |
| `gd` | remove a ticket reference, keeping its file for recovery |
| `gD` | explicitly confirm permanent deletion of the selected ticket file |
| `go` | recover an orphan ticket into a chosen state of its owning board |
| `gA` | archive/unarchive the board (all files are kept) |
| `R` | reload the view; asks before discarding edits across all columns |
| `q` | close the board tab and return to the originating tab (requires saved edits) |
| `g?` | list mappings |

Override mappings through `tasks.keymaps`; set entries to `false` to disable them.
Clean views refresh on writes and focus; dirty sessions retain their lines. Cursor movement
does not read files. Typing updates cached metadata decorations with a short debounce;
resizing updates decorations without rereading Markdown.

### Storage and format

The default layout is:

```text
stdpath("data")/Aero/workspaces/<workspace-name-hash>/tasks/
  <board-title>-board-<stable-id>/
    board.md
    tickets/
      task-<stable-id>.md
```

All worktrees of a repository share this directory. Each board owns a separate ticket
folder; cross-board transfers and links are rejected. Directory resolution and discovery
do not create files. `tasks.directory` supports:

- `"data"`: the default layout above.
- `"worktree"`: `<workspace.root>/.aero/tasks` **in the main checkout**.
- An absolute custom root: `<custom-root>/<workspace-name-hash>/tasks`.
- A relative path: an exact path relative to the workspace root.
- `function(workspace_root)`: an exact directory, with relative results resolved against that root.

Existing report paths and `state.json` retain their formats. No migration is required,
and no task metadata is written to `state.json`. Changing the task directory selects a
different storage location; move whole board folders yourself to migrate existing boards.
Removing a workspace registration keeps its task files.

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

Notes and comments remain ordinary Markdown.

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

Both document types require `aero_type`, `schema_version: 1`, a stable nonempty `id`,
and a nonempty single-line `title`. Optional `created_at` and `updated_at` use quoted
UTC timestamps (`YYYY-MM-DDTHH:MM:SSZ`); Aero fills them on creation and updates
`updated_at` on changes. `tags` and `assignees` are string lists; priority is
`low`, `normal`, `high`, or `urgent`; estimates are finite nonnegative numbers.
Unknown frontmatter keys are retained. Invalid types, dates, duplicate keys, and unsupported
versions are diagnosed. Aero does not write through invalid document metadata.

Frontmatter titles are authoritative. Renaming updates a matching body title heading and
ticket link label; folder names and ticket filenames stay stable. Level-two headings outside
fenced code blocks define states; heading order, containing section, and link order define
state order, status, and ticket order. Ticket status is not duplicated in frontmatter.
References resolve only inside the owning board's direct `tickets/` directory. Generated
labels escape Markdown brackets/backslashes; destinations are percent-encoded for spaces
and punctuation. Symlinked board folders and ticket aliases are rejected.

Edit these Markdown files directly, including descriptions, acceptance criteria, and custom
frontmatter. `yq` performs YAML round-trip edits to frontmatter while Markdown body edits
remain targeted. Unknown fields, comments, anchors/aliases, and block/flow styles are retained;
frontmatter whitespace and indentation may normalize, and edited metadata values may change
style to JSON-compatible YAML. Comments removed with replaced collection elements are kept
as standalone frontmatter comments. User metadata is passed as data to fixed `yq` expressions,
and the edited frontmatter is revalidated before any write; edits that would break alias
dependencies are refused. Both block and flow-style top-level mappings are supported.

### Persistence and conflicts

Mutations take an exclusive workspace lock at `<task-directory>/.aero-tasks.lock`, storing
host, PID, creation time, and a unique ownership token. Live owners are never displaced.
A same-host lock whose PID no longer exists is recovered automatically. Remote-owner,
unreadable, or ambiguous locks require manual removal after verifying the owner is gone.

Aero re-reads sources under the lock, rejects modified Neovim buffers, compares the original
content before committing, and writes through an exclusively created same-directory temporary
file followed by atomic rename. Unmodified open buffers are refreshed. External editors do
not honor Aero locks: detected conflicts stop the update and require refresh/retry; there is
still a small filesystem race between the final comparison and replacement.

Markdown provides no multi-file transaction. Creating a ticket writes its file before its
board reference; if the board update fails, the ticket remains an orphan recoverable with `o`.
Renaming a ticket writes its metadata before updating the board label; a failed label update
is reported, and the UI continues to use the frontmatter title. Permanent deletion removes
the reference first; a failure leaves the file as an orphan. No automatic cleanup removes
user-authored task files.

### Lua APIs

UI APIs are `require("aero").board(action, workspace)`, `.ticket(action)`, and
`.open_board(workspace, board_path)`. Workspace context comes from the sidebar selection,
current task buffer, active repository/worktree, or active board; ambiguous registered
workspaces prompt for a choice. A workspace argument is `{ root = "/path/to/main-checkout" }`.

The headless service is `require("aero.tasks")`; operations return a model/`true` or `nil, error`:

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
`remove_ticket` (fourth argument `true` permanently deletes), `archive_board`, and
`delete_board`. `move_ticket` also recovers an orphan belonging to the same board.

## Lifecycle events

Register lifecycle handlers in `setup()`. For example, open a newly created worktree in
[oil.nvim](https://github.com/stevearc/oil.nvim):

```lua
require("aero").setup({
  events = {
    worktree_created = function(event)
      require("aero").open_worktree(event.path, function(dir)
        require("oil").open(dir)
      end)
    end,
  },
})
```

`worktree_created` fires only after Git successfully creates the worktree and Aero's
completion callback finishes refreshing its state. `open_worktree(path, opener)` switches
to the worktree tab and focuses its code window before calling `opener(path)`, so Oil does
not replace the dashboard or agent panel. Without an opener, it restores the worktree's last
code buffer, falling back to `:edit` on the directory. An explicit opener always takes precedence.

You can also subscribe before or after setup:

```lua
local aero = require("aero")

local unsubscribe = aero.on("session_exited", function(event)
  vim.notify(event.name .. " exited with code " .. event.exit_code)
end)

aero.once("worktree_created", function(event)
  vim.notify("First new worktree: " .. event.path)
end)

-- Later:
unsubscribe()
-- Alternatively: aero.off(event_name, original_callback)
```

Each handler receives a data table with an `event` field containing its name. Lua handlers
run in registration order on Neovim's main thread, with a separate copy of the data for each
handler. Errors are reported without stopping the remaining Lua handlers. Use `"*"` to
subscribe to all events. A setup entry may be a function or a list of functions; repeating
`setup()` replaces its configured handlers while preserving subscriptions made with `on()`.

| Event                                  | Additional data / timing                                                                                                            |
| -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `setup`                                | Setup has completed.                                                                                                                |
| `workspace_added`, `workspace_removed` | `root`, `name`; after updating the registry.                                                                                        |
| `worktree_created`                     | `root`, `path`, `branch`; after successful creation and its completion callback.                                                    |
| `worktree_removed`                     | `root`, `path`, `force`; after successful removal and its completion callback.                                                      |
| `worktree_entered`                     | `path`, `tab`, `created`; after entering a worktree tab (`created` means a new tab).                                                |
| `session_created`                      | Session metadata; after registration.                                                                                               |
| `session_started`                      | Session metadata plus `win`, `type`, `resume`; after launching the backend. `resume` is the requested behavior.                     |
| `session_ready`                        | ACP only: session metadata plus `session_id`, `type`, `resumed`; after initializing/loading. `resumed` reports actual success.      |
| `session_resume_failed`                | ACP only: session metadata plus `session_id`, `type`, and the adapter's full `error` object; saved conversation retained for retry. |
| `session_model_changed`                | ACP only: session metadata plus `session_id`, `model_id`, `model_name`, and `previous_model_id`; confirmed model changes. |
| `session_mode_changed`                 | ACP only: session metadata plus `session_id`, `mode_id`, `mode_name`, and `previous_mode_id`; confirmed mode changes. |
| `session_shown`                        | Session metadata plus `win`; after showing or reusing its window.                                                                   |
| `session_stopped`                      | Session metadata; after requesting that a running backend stop.                                                                     |
| `session_exited`                       | Session metadata plus `exit_code`, `type`; after the current backend exits.                                                         |
| `session_deleted`                      | Session metadata; after deleting its registration and history.                                                                      |
| `dashboard_opened`, `dashboard_closed` | `win`, `buf`, `tab`.                                                                                                                |
| `panel_opened`, `panel_closed`         | `win`, `tab`; agent-panel window opened/closed.                                                                                     |
| `terminal_opened`                      | `worktree`, `win`, `buf`, `fresh`; worktree shell shown, with `fresh` indicating a new process.                                     |
| `terminal_closed`                      | `worktree`, `win`, `buf`; shell window hidden (the process continues).                                                              |
| `fullscreen_entered`                   | `kind`, `tab`, `source_tab`, `win`, `source_win`, `buf`.                                                                            |
| `fullscreen_exited`                    | `kind`, `tab`, `win`, `buf`; original pane, including when the fullscreen tab is closed manually.                                   |

Session metadata includes `key`, `name`, `agent`, `worktree`, and `buf` when a buffer exists.
Events describe Aero operations; they do not watch worktrees created by external Git commands.

The same events are exposed as Neovim `User` autocmds, using PascalCase names prefixed with
`Aero`. Data is available through `event.data`:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "AeroWorktreeCreated",
  callback = function(event)
    vim.notify("Created " .. event.data.path)
  end,
})
```

## Configuration

```lua
require("aero").setup({
  agents = {
    -- terminal agents
    claude = { cmd = { "claude" }, resume = { "claude", "--continue" }, key = "c" },
    codex = { cmd = { "codex" }, resume = { "codex", "resume", "--last" }, key = "x" },
    opencode = { cmd = { "opencode" }, resume = { "opencode", "--continue" }, key = "o" },
    -- ACP agents
    ["claude-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/claude-agent-acp" }, key = "C" },
    ["codex-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/codex-acp" }, key = "X" },
    ["opencode-acp"] = { type = "acp", cmd = { "opencode", "acp" }, key = "O" },
    -- add your own; set an entry to false to remove a default
    -- gemini = { type = "acp", cmd = { "gemini", "--experimental-acp" }, key = "g" },
  },
  worktree_path = function(ws, branch) -- default: <repo>/../<repo>.worktrees/<branch>
    return vim.fs.joinpath(vim.fs.dirname(ws.root), vim.fs.basename(ws.root) .. ".worktrees", (branch:gsub("/", "-")))
  end,
  dashboard = { position = "left", width = 40 }, -- "left" | "right" | "current" (oil-style)
  panel = { position = "right", width = 80 },    -- where sessions open; false = last used window
  worktree_tabs = true,    -- one tab per worktree, :tcd'd to it
  terminal = { height = 12, cmd = nil }, -- worktree shell; cmd defaults to { vim.o.shell }
  idle_ms = 1500,          -- terminal agents: no output for this long = idle
  notify_idle = true,      -- notify when a hidden session finishes
  start_insert = true,     -- enter insert / the prompt buffer when opening a session
  animation = true,        -- spinner + live activity ("thinking", the running tool, elapsed time)
  fullscreen_key = "gF",   -- normal-mode key in every pane, including code; false disables it
  quote_key = "<leader>aq", -- visual-mode quote from code or agent logs; false disables it
  resize = { prefix = "<C-w>", keys = { grow = "k", shrink = "j", narrow = "h", widen = "l" } }, -- false disables it
  persist_sessions = true,
  persist_buffers = true,  -- remember each worktree's last code file/directory and cursor
  state_file = vim.fn.stdpath("data") .. "/Aero/state.json",
  events = {},            -- lifecycle event -> function or list of functions; see above
  acp = { max_tool_lines = 20, prompt_height = 25, decorations = true, show_usage = true },
  reports = {
    directory = "data", -- "worktree", a custom path, or a directory function
    prompt = "Report file: {path}\nRead this Markdown report for context and write or update the report at this path with your findings.",
  },
  tasks = {
    directory = "data", -- workspace-scoped; "worktree" uses the main checkout
    yq = "yq", -- Mike Farah's Go-based yq v4 executable
    states = { "backlog", "todo", "in progress", "review", "test", "done" },
    terminal_states = { "done" },
    estimate_unit = "points",
    -- column_width = 32,
    -- keymaps = { move = "m", new = "ga", states = "gs", ... },
  },
  icons = {
    expanded = "▾",
    collapsed = "▸",
    busy = "◐",
    idle = "●",
    waiting = "?",
    exited = "✗",
    stopped = "○",
  },
  keymaps = { -- dashboard keymaps; set any to false to disable it
    open = "<CR>",
    expand = "l",
    collapse = "h",
    toggle = "<Tab>",
    open_vsplit = "<C-v>",
    open_split = "<C-x>",
    open_tab = "<C-t>",
    add = "a",
    add_workspace = "A",
    delete = "d",
    stop = "s",
    restart = "r",
    rename = "N",
    refresh = "R",
    pull = "P",
    cd = ".",
    edit = "e",
    edit_enter = "<C-CR>", -- open the selected worktree in the code pane
    edit_mouse = "<C-LeftMouse>", -- open the clicked worktree in the code pane
    terminal = "t",
    next_workspace = "]]",
    prev_workspace = "[[",
    close = "q",
    help = "g?",
  },
})
```

Statusline: `require("aero").statusline()` returns e.g. `?1 ◐2 ●1` (waiting / busy / idle).

Highlights (all `default` links): `AeroWorkspace`, `AeroWorktree`, `AeroMain`, `AeroBusy`,
`AeroIdle`, `AeroWaiting`, `AeroExited`, `AeroStopped`, `AeroDim`, `AeroTitle`.

Transcript highlights: `AeroChatUser`, `AeroChatAgent`, `AeroChatThinking`, `AeroChatTool`,
`AeroChatCommand`, `AeroChatMeta`, `AeroChatError`, `AeroChatSuccess`, `AeroChatPending`,
`AeroChatBorder`, `AeroChatHeader`. These are default links to your colorscheme's existing
groups; override them with `vim.api.nvim_set_hl()` to customize the appearance.

Run `:checkhealth Aero` to check git and the agent executables.
