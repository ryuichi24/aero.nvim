# Workspaces and worktrees

Manage repositories, Git checkouts, and their sessions from the dashboard.

[Back to README](../README.md)

A **workspace** is a Git repository (its main worktree), registered across restarts.
**Worktrees** are read live from `git worktree list`. Each worktree can have multiple
terminal or ACP sessions. See [agents](agents.md) for session controls.

## Commands

| Command | Description |
| --- | --- |
| `:Aero` / `:Aero toggle` | Toggle the dashboard in the current tab |
| `:Aero open` / `:Aero close` | Show and focus / explicitly hide the dashboard |
| `:Aero add [path]` | Register the repository containing the path (default: cwd) |
| `:Aero pick` | Pick any session using `vim.ui.select` |
| `:Aero sessions` | Search active sessions across worktrees in a live popup |
| `:Aero inbox` | Review ACP permissions, errors, and completed turns across worktrees |
| `:Aero worktrees` | Search worktrees grouped by workspace and open the selected checkout |
| `:Aero workspaces` | Search registered workspaces and open the selected root checkout |
| `:Aero refresh` | Re-read worktrees |
| `:Aero pull` | Pull the selected worktree's upstream, fast-forward only |
| `:Aero term` | Toggle the current worktree's shell |

The session, worktree, and workspace popups open in normal mode. Use `j`/`k` to
select, `i` to filter, and `Enter` to open the selected item. `Esc` returns to
normal mode; `q` in normal mode closes the popup. Worktree search matches workspace
names, paths, and branch names. Selecting a worktree or workspace focuses its code
window, reusing its tab when available.

The matching Lua APIs can be passed directly to keymaps:

```lua
local aero = require("aero")
vim.keymap.set("n", "<leader>as", aero.sessions, { desc = "Search active AI sessions" })
vim.keymap.set("n", "<leader>ai", aero.inbox, { desc = "Agent attention inbox" })
vim.keymap.set("n", "<leader>aw", aero.worktrees, { desc = "Search worktrees" })
vim.keymap.set("n", "<leader>aW", aero.workspaces, { desc = "Search workspaces" })
```

## Renaming worktree folders

Renaming a Git branch does not rename its checkout directory. To move or rename
the directory, use Git so its worktree metadata stays in sync:

```sh
git -C /path/to/main-repository worktree move /path/to/old-folder /path/to/new-folder
```

If you already renamed the folder manually, repair its registration:

```sh
git -C /path/to/main-repository worktree repair /path/to/new-folder
```

Then run `:Aero refresh` to re-read the paths. Aero reports missing directories
before opening a checkout. Existing sessions retain their saved worktree paths;
repairing Git's registration does not relocate those sessions.

## Attention inbox

`:Aero inbox` collects events from ACP conversations in this Neovim instance, across
workspaces and worktrees. Entries are newest first and show the event type, session
name, agent, workspace/worktree paths, and assigned ticket ID when available.
Assignment context is captured when the event occurs; unassigned sessions also appear.

- **permission:** a live request awaiting an answer. Resolved or cancelled requests
  disappear automatically.
- **error:** a session/turn error, including failed requests and nonzero adapter exits.
- **completed:** a successfully completed prompt turn. Cancelled or otherwise stopped
  turns do not count as successful completions.

Use `j`/`k`, arrows, or `Ctrl-n`/`Ctrl-p` to select, `i` to filter by words, and
`Enter` to open the event. Permission entries jump to their live options; errors jump
to their error text; completions jump to the corresponding user prompt in the transcript.
Opening marks the event read. Normal-mode `r` marks it read without opening, `d`
dismisses it, and `q` closes the picker. `Esc` leaves insert-mode filtering; `r`,
`d`, and `q` remain ordinary search text in insert mode.

Read and dismissed entries leave the inbox and the same event is not surfaced again.
A later distinct event from the same session still appears. Error and completion
events remain after the agent becomes idle or exits; opening an exited transcript
does not restart the agent. Forgotten/replaced conversations are removed, and missing
worktrees or transcript buffers are reported when opening. An empty inbox reports
“no attention events”; a filter with no results shows “No matching attention events”.

Inbox events and read/dismiss state last for the current Neovim instance, not across
restarts. Saved transcript replay does not create new inbox events. Terminal-agent
output is not used to infer completion or errors. Inbox actions never answer a
permission, submit a prompt, or change ticket state.

## Dashboard toggle

The dashboard toggles even when focus is in code, a prompt, or a terminal.

```lua
vim.keymap.set("n", "<leader>ad", "<cmd>Aero toggle<cr>")
vim.keymap.set("i", "<leader>ad", "<Esc><cmd>Aero toggle<cr>")
vim.keymap.set("t", "<leader>ad", "<C-\\><C-n><cmd>Aero toggle<cr>")
```

## Dashboard keys

| Key | Action |
| --- | --- |
| `<CR>` | Open session / toggle node |
| `l` / `h` | Expand or step into / collapse or go to parent |
| `<C-v>` / `<C-x>` / `<C-t>` | Open session in vsplit / split / tab |
| `a` | On workspace: create worktree; on worktree: create a chosen agent session |
| `c` / `x` / `o` | Open Claude / Codex / OpenCode terminal session |
| `C` / `X` / `O` | Open Claude / Codex / OpenCode ACP session |
| `A` | Add workspace |
| `d` | Delete session/report with confirmation, remove worktree, or forget workspace |
| `s` / `r` | Stop / restart (resume) session |
| `N` | Rename selected session, report, or board |
| `.` / `e` | Set tab cwd to worktree / restore its code buffer |
| `<C-LeftMouse>` / `<C-CR>` | Open worktree's code pane without starting an agent |
| `t` / `P` | Open shell / pull upstream |
| `]]` / `[[` | Next / previous workspace |
| `R` / `q` / `g?` | Refresh / close / help |
| `gF` | Toggle fullscreen |

All agent keys always create a fresh session: lowercase keys (`c`, `x`, `o` by
default) start terminal agents, and uppercase keys (`C`, `X`, `O`) start ACP agents.
With `a`, choose an agent first. Both `a` and agent shortcuts then prompt for a
unique session name; cancelling or submitting an empty name creates
nothing. Set `prompt_session_name = false` in `setup()` to use automatic names instead.
Ctrl-click also works on workspace
and session rows, opening the corresponding worktree. Enable mouse support with
`:set mouse=a`. Override mappings through `keymaps`; set an entry to `false` to disable it.

## Worktree tabs and remembered buffers

Each worktree gets a tab with `:tcd` set to its checkout. Opening a session, using
`:Aero pick`, or pressing `e` enters that tab. File pickers, `:e`, grep, and LSP operate
on that checkout, while each tab retains its windows and agent panel.

- Existing tabs inside a worktree are reused.
- New tabs bring the dashboard and restore the last code file/directory and cursor.
- Removing a worktree closes its tab.
- `worktree_tabs = false` keeps everything in the current tab.

Code-buffer memory includes Oil directories. Live buffers are reused, preserving unsaved
edits within the same Neovim instance. Across restarts Aero reopens the saved path;
missing paths fall back to the worktree directory. Dashboard, prompt, transcript, and
terminal buffers do not replace this selection. This also works without worktree tabs.

`persist_buffers = false` disables cross-restart buffer memory. Aero stores paths and
cursor positions, not unsaved contents. See [persistence](persistence.md).

## Worktree terminal

`:Aero term` opens a shell below the code window in the current worktree; `t` opens
the dashboard-selected worktree's shell. Each worktree has its own process. Hiding
the shell keeps it running, and dashboard file opens never replace the shell window.

## Pulling a worktree

Opening the dashboard or pressing `R` fetches all remotes asynchronously for each
expanded workspace and shows tracking status beside each branch. `[pull ↓N]`
means the branch is behind its upstream by N commits: select it and press `P` to
pull. Other statuses are `[up to date]`, `[ahead ↑N]`, `[diverged ↑N ↓N]`,
`[no upstream]`, and `[upstream gone]`. Diverged branches cannot be pulled with
fast-forward only. While checking, rows show `[checking remote…]`; if the fetch
fails they show `[fetch failed]` rather than a potentially stale status. Fetching
does not change worktree files. Status reflects the latest completed fetch;
press `R` to check again.

`P` or `:Aero pull` runs `git -C <worktree> pull --ff-only` asynchronously using its
configured upstream. Workspace rows select the main checkout; session rows select
their worktree. Outside the dashboard, selection uses the focused agent, current tab's
worktree, or cwd. The Lua API accepts an explicit path: `require("aero").pull(path)`.

A successful pull refreshes the dashboard and unmodified open files. Output/errors
appear in notifications. Pulling does not change tabs or cwd, and duplicate concurrent
pulls of a worktree are ignored. Divergent branches, missing upstreams, and changes Git
cannot preserve are reported rather than merged automatically.
