# Agents and ACP conversations

Run agent CLIs in terminals or use native Neovim chat buffers over ACP.

[Back to README](../README.md)

Fresh ACP sessions can be bound to a persisted Kanban ticket with opt-in
[agent task integration](agent-tasks.md). Assigned task files use revision-checked
MCP tools instead of generic ACP file writes.

## Agent setup

Terminal agents run `opencode`, `claude`, or `codex` in `:terminal` buffers. Busy/idle
status is inferred from output activity. ACP agents use the
[Agent Client Protocol](https://agentclientprotocol.com) over stdio for structured
transcripts, prompts, permissions, and session controls.

| Agent | Key | Launch | Terminal resume |
| --- | --- | --- | --- |
| OpenCode | `o` | `opencode` | `opencode --continue` |
| Claude Code | `c` | `claude` | `claude --continue` |
| Codex | `x` | `codex` | `codex resume --last` |
| OpenCode ACP | `O` | `opencode acp` | Uses ACP `session/load` |
| Claude ACP | `C` | `npx -y @agentclientprotocol/claude-agent-acp` | Uses ACP `session/load` |
| Codex ACP | `X` | `npx -y @agentclientprotocol/codex-acp` | Uses ACP `session/load` |

Install your agent and configure its providers, models, and credentials using the
agent's own setup. OpenCode needs no separate adapter. Claude/Codex ACP use the official
adapters through `npx`; install them globally and configure `cmd` to use their binary
for faster startup. Agent definitions are replaced wholesale:

```lua
require("aero").setup({
  agents = {
    opencode = { cmd = { "opencode" }, resume = { "opencode", "--continue" }, key = "o" },
    ["opencode-acp"] = { type = "acp", cmd = { "opencode", "acp" }, key = "O" },
  },
})
```

## Transcript and prompt

Transcripts are read-only Markdown with native highlighting and virtual borders:

- Numbered prompt turns with a preview of your prompt, labeled agent Messages, and muted Thinking sections.
- Consecutive tool calls grouped into compact, expandable summaries between messages.
- Typed tool cards with status, locations, output, and diffs.
- Command cards with shell input, working directory when available, and output.
- Compact Session cards for model changes and session events.
- Highlighted errors and selectable permission options.

`acp.max_tool_lines` limits displayed tool output (default 20) with an omitted-line count.
Streaming preserves the earlier transcript view. Borders and shell `$` decorations
are excluded from yanks/quotes. No Markdown renderer is needed; disable decorations
with `acp = { decorations = false }`.

Prompt turns start expanded; tool groups and individual tool details start folded.
Use `za`, `zo`, and `zc` to toggle, open, and close the section under the cursor;
`zM` collapses the conversation into a prompt outline, and `zR` expands everything.
Opening a tool group shows one-line call summaries; open a call to inspect its output.
Failed calls and new permission requests automatically expose their containing sections.
Fold choices and your reading position are retained while output streams. Folds are
window-local presentation state and do not change saved history or `/export` output.
Existing saved histories receive the same grouping; events before the first prompt
appear under **Session setup**. Agent Messages show the explanations and decisions
the agent sends; Thinking sections appear only when reported by the agent.

The transcript's top bar shows the latest **todo progress** and what the agent is
working on, alongside the panel's session details. It stays visible while you
scroll the logs and in fullscreen. Todos follow ACP plan updates and
`todowrite`/`todoread` tool calls,
including saved conversation history; plan and todo tool cards in the logs use
the same readable checklist formatting.

Live todo changes also show session-labeled popups in the editor's
upper-right corner, even for background ACP sessions. Each session has its own
checklist; changes update its popup without moving your cursor. Popups follow you
across tabs. Run `:Aero todos` to focus the most recently updated popup, or enter
one with the mouse or window navigation to scroll it, and
press `q` or Escape to dismiss it; the next change shows it again. On small screens,
the newest sessions take priority. Restored history does not trigger notifications.
Disable these popups with `acp = { todo_notifications = false }`.

Popups automatically close 15 seconds after their last todo change. Configure
`acp.todo_notification_timeout` in milliseconds; `0` keeps them open until dismissed.
Focusing a popup pauses its timeout; leaving it starts a fresh timeout.
If all popups have closed, `:Aero todos` reopens the latest session's todo popup.

```lua
require("aero").setup({
  acp = { todo_notification_timeout = 10000 }, -- 10 seconds; 0 disables auto-close
})
vim.keymap.set("n", "<leader>at", "<cmd>Aero todos<CR>", { desc = "Focus agent todo popup" })
```

| Transcript key | Action |
| --- | --- |
| `i`, `a`, `o`, `I`, `A`, `<CR>` | Open prompt below transcript |
| `<CR>` on an option / `1`–`9` | Answer pending permission |
| `p` | Jump to pending permission |
| `gY` | Toggle auto yes for this conversation |
| `<C-g>` | Toggle the input panel, keeping the draft |
| `<C-c>` | Cancel the turn and pending request |
| `]]` / `[[` | Jump to the next / previous prompt turn |
| `za` / `zo` / `zc` | Toggle / open / close the current turn or tool section |
| `zM` / `zR` | Collapse the conversation outline / expand everything |
| `gP` | Search prompt history and jump to a prompt |

Permission requests with an allow option also offer **Auto yes for this conversation**,
including in the companion. Selecting it approves the pending requests and automatically
allows future requests in this conversation. Aero prefers the agent's allow-once option;
requests without an allow option still require an answer. Auto-approved requests remain
in the transcript. Press `gY` in the transcript to toggle the mode off or on. The mode
is runtime-only and is reset to the setup default when the conversation is replaced
or Neovim restarts. Enable it by default for ACP conversations with:

```lua
require("aero").setup({
  acp = { auto_yes = true },
})
```

The default is `false`. `gY` still overrides it for the current conversation.

The prompt is a regular Markdown buffer; closing it retains the draft.
With `persist_sessions = true` (the default), unfinished prompts are automatically
saved per session and restored when you reopen the session after restarting Neovim.
Submit with `:Aero prompt send` or Ctrl-Enter; `:w` keeps the draft and Ctrl-s has no submit binding.
You can also type `/send` on its own line and press Enter. Aero removes that line
and submits the remaining draft; an empty draft sends nothing.
Your terminal must send Ctrl-Enter as a distinct key (for example, using Kitty's keyboard protocol).

| Prompt key | Action |
| --- | --- |
| `:Aero prompt send` | Submit the selected ACP session's draft |
| `<C-CR>` | Submit the draft in normal or insert mode (Ctrl-Enter) |
| `<CR>` | Run a local slash command or insert a newline |
| `<C-x><C-o>` | Complete slash commands |
| `<C-n>` / `<C-p>` | Next / previous suggestion |
| `<Tab>` / `<S-Tab>` | Next / previous suggestion when `acp.tab_completion = true` |
| `@` (insert mode) | Show inline fuzzy suggestions for worktree files and folders |
| `q` | Close in normal mode |
| `<C-g>` | Toggle the input panel in normal or insert mode, keeping the draft |
| `<C-c>` | Cancel the turn |

Slash-command suggestions appear automatically as you type `/`, including agent-provided
commands and descriptions. `/model ` and `/mode ` suggest available IDs.
The highlighted slash command's full description appears in a wrapped popup beside
the suggestion list and updates as you navigate.
Use Ctrl-n/Ctrl-p or the arrow keys to navigate; Enter accepts a suggestion (the first
one if none is selected). Ctrl-e dismisses the menu. Accepting a suggestion does not
send the prompt; press Enter again to run `/report`, `/export`, or `/cancel`.

Tab and Shift-Tab navigate Aero suggestions by default. To leave them available for
your own mappings (for example, accepting Supermaven suggestions), disable them:

```lua
require("aero").setup({
  acp = { tab_completion = false },
})
```

Type `@` anywhere after whitespace in your draft to suggest worktree paths inline.
Keep typing to fuzzy-filter the list (for example, `@sne` can match
`src/nested/example.lua`). Use the same navigation keys and Enter to insert the
selected `@path`. Folder paths end in `/`, and paths containing spaces are quoted.
The menu appears below the query, or above the draft line when space below is
limited, keeping wrapped text visible. Navigation leaves your query unchanged
until you press Enter. The menu stays within the panel's width; Ctrl-e dismisses it so you can
continue typing a literal mention. Git worktrees exclude ignored paths.

Ctrl-n moves down and Ctrl-p moves up in the path suggestions without changing
your query. Aero disables native LSP completion and the default completion of
nvim-cmp, blink.cmp, mini.completion, and coc.nvim in its prompt buffers to keep
their suggestions from overlapping Aero's menu.

`:Aero cancel` selects the focused/dashboard-selected ACP agent or the current tab's
panel session, even if hidden. `/cancel` also works. Cancellation discards queued
prompts and pending permissions while retaining the conversation; continue after
the agent acknowledges cancellation.

## Add the current source file

Run `:Aero file` while focused on a named source file to append its absolute path
to the current tab's panel session's draft and open the composer without submitting.
Existing draft text is preserved, and paths containing whitespace are quoted.
Terminal agents receive the path as bracketed paste. An unnamed or special buffer
reports a message instead.

Create your own mapping (no default key is assigned):

```lua
vim.keymap.set("n", "<leader>af", function()
  require("aero").file()
end, {
  desc = "Aero: add current file to agent prompt",
})
```

The same action is available as `require("aero").file()`.

## Prompt snippets

Type `/prompt` in the ACP composer to choose a custom prompt from a searchable
popup with a full-text preview. Snippets are loaded from user-owned global and
workspace JSON files and inserted into the draft for editing before sending.
See [Prompt snippets](prompt-snippets.md) for file locations and the JSON format.

## Prompt history

Use `:Aero prompts`, or `gP` in an ACP transcript, to review that session's submitted
prompts in chronological order. The selected prompt is previewed in full;
`Ctrl-d`/`Ctrl-u` scroll the preview, and `Enter` jumps to its chat log line.
Use `i` to filter, `j`/`k` to select, and `q` to close. Empty sessions report no prompts.

Type `/history` on its own line in the composer and press Enter to open the same
picker for reuse. Selecting a prompt inserts its full text into the composer,
appending it to any existing draft for editing before sending.

## Inline image previews in Kitty

ACP image messages and images in tool results (including Playwright MCP
screenshots) can appear directly in the transcript using
[image.nvim](https://github.com/3rd/image.nvim). Enable Aero's image links:

```lua
require("aero").setup({
  acp = { image_previews = true },
})
```

Install ImageMagick (`brew install imagemagick` on macOS), and configure
`image.nvim`. With Neovim's built-in `vim.pack`, load it before Aero's setup:

```lua
vim.pack.add({ "https://github.com/3rd/image.nvim" })

require("image").setup({
  backend = "kitty",
  processor = "magick_cli",
  integrations = {
    markdown = {
      enabled = true,
      floating_windows = true,
      download_remote_images = false,
      only_render_image_at_cursor = false,
    },
  },
  max_height_window_percentage = 50,
})
```

The Markdown integration also requires the `markdown` and `markdown_inline`
Tree-sitter parsers. `floating_windows = true` allows previews in Aero's floating
transcript panels. Image.nvim manages image placement, scrolling, and resizing.
If using tmux, enable `allow-passthrough` and `focus-events` as described in
image.nvim's setup guide.

Aero caches embedded PNG, JPEG, GIF, WebP, and AVIF payloads under
`stdpath("cache")/aero/images`; repeated images share the same file. Saved ACP
history retains the original payload, so previews can be rebuilt after clearing
the cache. Image previews are opt-in; unsupported or invalid payloads and exported
transcripts retain the `[image]` label. The agent's ACP adapter must forward image
content: a screenshot filename alone does not provide an embedded image.

For Mermaid diagrams in transcripts and Markdown files, see
[Markdown diagram previews](markdown.md).

## Permissions and file access

Requests display numbered choices. The transcript cursor moves to the options, but
focus only moves if you were already in the transcript; otherwise Aero notifies you.
`:Aero prompt` or reopening the session takes you to a pending request. Waiting
sessions display `?` in the dashboard.

ACP `fs/read_text_file` reads loaded buffers so agents see unsaved changes;
`fs/write_text_file` writes through loaded buffers. Aero does not offer ACP
`terminal/*` delegation; agents execute commands themselves.

## Models and modes

Send `/model` or `/mode` to open a picker, or supply an ID/unambiguous display name:

```text
/model provider/model-id
/mode plan
/mode build
```

Available choices come from the agent and the current selection appears in the panel
title. `<C-x><C-o>` completes commands and IDs. Aero handles them locally, preserving
the conversation. It prefers ACP config options, with legacy `session/set_model` and
`session/set_mode` fallbacks. Metadata refreshes on load and agent updates.

While busy, changes wait for the current turn and run before later queued prompts.
Cancelled pickers/rejected changes leave the selection unchanged. Unsupported controls
are reported. Terminal sessions use their CLI's own controls.

## Tokens, context, and fees

`:Aero usage` reports available metrics for the focused or dashboard-selected session,
including unopened saved sessions without starting the agent. ACP transcripts have a
Usage card; panel/dashboard summaries show metrics, including context percentages.

- **Tokens:** accumulated reported prompt-response turns. Agent `totalTokens` is
  authoritative; otherwise reported input plus output is used when both exist.
  Reasoning/cache breakdowns are included when reported, not estimated.
- **Context:** latest reported occupancy/capacity, separate from consumed tokens;
  it may decrease after compaction. Percentages are omitted for zero capacity.
- **Fee:** latest cumulative session cost in the reported currency. Updates replace
  previous snapshots, never sum them. Aero does not infer model prices.

Missing metrics show as **not reported**; reported zero fees remain zero. Metrics
persist with history, remain on resume, and reset for new conversations. They do not
include unreported model calls or older activity Aero never received.

`acp = { show_usage = false }` hides automatic displays while continuing tracking.
`require("aero").usage()` shows the report and returns a copy of available `tokens`,
`context`, and `cost`, or `nil`. See [persistence and recovery](persistence.md).
