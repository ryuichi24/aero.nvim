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

- Separate user/agent headings and muted thinking sections.
- Typed tool cards with status, locations, output, and diffs.
- Command cards with shell input, working directory when available, and output.
- Compact Session cards for model changes and session events.
- Highlighted errors and selectable permission options.

`acp.max_tool_lines` limits displayed tool output (default 20) with an omitted-line count.
Streaming preserves the earlier transcript view. Borders and shell `$` decorations
are excluded from yanks/quotes. No Markdown renderer is needed; disable decorations
with `acp = { decorations = false }`.

The transcript's top bar shows the latest **todo progress** and what the agent is
working on, alongside the panel's session details. It stays visible while you
scroll the logs and in fullscreen. Press `gT` to open a live, scrollable todo list
with status icons, highlighting, and priorities when reported. Close it with
`q` or Escape. Todos follow ACP plan updates and `todowrite`/`todoread` tool calls,
including saved conversation history; plan and todo tool cards in the logs use
the same readable checklist formatting.

| Transcript key | Action |
| --- | --- |
| `i`, `a`, `o`, `I`, `A`, `<CR>` | Open prompt below transcript |
| `<CR>` on an option / `1`–`9` | Answer pending permission |
| `p` | Jump to pending permission |
| `gT` | Open live agent todos |
| `<C-c>` | Cancel the turn and pending request |

The prompt is a regular Markdown buffer; closing it retains the draft.

| Prompt key | Action |
| --- | --- |
| `:w` / `<C-s>` | Send (Ctrl-s works in normal and insert mode) |
| `<CR>` | Send in normal mode |
| `<C-x><C-o>` | Complete slash commands |
| `<Tab>` / `<S-Tab>` | Next / previous suggestion in the automatic slash-command menu |
| `@` (insert mode) | Show inline fuzzy suggestions for worktree files and folders |
| `q` | Close in normal mode |
| `<C-c>` | Cancel the turn |

Slash-command suggestions appear automatically as you type `/`, including agent-provided
commands and descriptions. `/model ` and `/mode ` suggest available IDs. Use Tab/Shift-Tab,
Ctrl-n/Ctrl-p, or the arrow keys to navigate; Enter accepts a suggestion (the first
one if none is selected). Ctrl-e dismisses the menu. Accepting a suggestion does not
send the prompt; press Enter again to run `/report`, `/export`, or `/cancel`.

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
