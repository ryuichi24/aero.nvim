# Persistence and recovery

Restore saved workspaces and logs, and reconnect agents to their own conversations.

[Back to README](../README.md)

## Saved state

State lives at `stdpath("data")/Aero/state.json`, configurable through `state_file`.
Changes merge into the latest state and replace it atomically so multiple Neovim
instances can share it. Logs live separately in `<state_file>.history/`.

| Data | Restored behavior |
| --- | --- |
| Workspaces | Registered repos and expanded/collapsed state |
| Sessions | Names, agent choices, and ACP IDs per worktree; processes start when opened |
| ACP transcripts | Messages, thoughts, tools, plans, permission outcomes, session ID, and usage metrics |
| Terminal scrollback | Saved text above new output, within terminal scrollback limits |
| Code buffers | Last file/directory/Oil path and cursor per worktree |

Snapshots are written during output and flushed on normal exit. Historical terminal
colors/cursor state are not retained. Deleting a session removes its saved log.
Unsaved code contents are not stored: live buffers are reused during the current instance,
while paths reopen across restarts.

`persist_sessions = false` disables session/log persistence; `persist_buffers = false`
independently disables cross-restart code-buffer memory. Use `NVIM_APPNAME=Aero-dev`
or a separate `state_file` for isolated development state.

## Resume and retry

Terminal sessions use `claude --continue`, `codex resume --last`, or `opencode --continue`.
ACP sessions use `session/load` with the saved conversation ID. Restoring the visible
transcript is separate from resuming the backend; true resume needs the agent's storage.

If ACP loading fails, Aero keeps the ID and transcript and stops the failed backend,
instead of creating a replacement conversation. The transcript shows the adapter's
error, code/data, and available stderr. Press `r` on the session to retry the same ID.
Queued prompts remain for a retry in the same Neovim instance. Use `a` on the worktree
to create a separate fresh session.

## Reconnect a known conversation

1. Find the original ID in the agent's saved sessions.
2. Select the ACP session in the dashboard or focus its transcript/prompt.
3. Run `:Aero resume <session-id>`.

The Lua API is `require("aero").resume(session_id)`. The new ID is saved only after
successful loading. The conversation replays its history, replacing a cache for a
different ID; cached errors do not suppress replay. Failed recovery preserves the
previous ID/transcript.

## Codex: “no rollout found for thread id”

A rollout is Codex's saved conversation file. This error means the process cannot find
one for the requested ID. Codex writes a rollout after the first user message, so an
unused session may have no conversation to restore.

Check the adapter's `CODEX_HOME` (normally `~/.codex`). Conversations live under
`sessions/` as `rollout-<timestamp>-<session-id>.jsonl`; the first record contains the
ID and working directory. Also check `archived_sessions/`.

An older fallback may have saved an unused replacement ID while the original rollout
still exists. Locate the worktree's original conversation and reconnect with
`:Aero resume <session-id>`. Retrying a missing ID cannot recreate its rollout;
the visible Aero log alone is not resumable backend state.
