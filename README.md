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
| `d`                     | delete session / `git worktree remove` / forget workspace                                                  |
| `s` / `r`               | stop / restart (resume) session                                                                            |
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
  panel = { position = "right", width = 70 },    -- where sessions open; false = last used window
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
  acp = { max_tool_lines = 20, prompt_height = 8, decorations = true },
  keymaps = { --[[ see lua/aero/config.lua; set any to false ]] },
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
