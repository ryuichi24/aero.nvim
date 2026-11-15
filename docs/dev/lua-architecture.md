# Lua ownership and dependency boundaries

The Lua implementation is organized by feature. Public modules retain their
existing `require("aero…")` paths; collaborators below them own narrower state,
protocol, transaction, or presentation responsibilities.

## Session runtime

`session.lua` is the lifecycle coordinator and public compatibility API.

| Collaborator | Ownership |
| --- | --- |
| `session/registry.lua` | Stable runtime identity, persisted-definition reconciliation, collision reservations, buffer lookup |
| `session/monitor.lua` | Polling timer, status transitions, idle notifications, spinner activation |
| `session/integrations.lua` | Ordered task restoration and reading/browser/knowledge attachment and deletion cleanup |
| `session/backends/terminal.lua` | PTY, terminal input/output, resize, scrollback, terminal history |
| `session/backends/acp.lua` | Session ownership adapter for ACP startup/stop/forget |
| `session/actions.lua` | Interactive create/choose/rename/restart/delete workflows using explicit worktrees |
| `session/picker.lua` | Session enumeration and labels with caller-supplied cache/navigation callbacks |

Saved session enumeration and already-materialized runtime enumeration are
different operations. Monitoring includes instantiated sessions even if another
Neovim instance removes their saved definitions. Renaming retains the original
identity and reserves it against later name collisions.

Successful backend startup has one finalization boundary: install wipe handling,
release the old buffer, start monitoring, clear stop state, publish changes, and
emit `session_started`. History-only ACP loading omits that final event. Failed
launches do not finalize startup.

## ACP conversations

`acp/conversation.lua` coordinates durable history, lifecycle events, and calls
between the protocol/state and editor collaborators.

- `connection.lua` negotiates capabilities and selects new/load-session behavior.
- `turns.lua` owns prompt preparation, readiness gating, FIFO dispatch, and turn completion.
- `updates.lua` mutates notification state and returns explicit effect descriptions.
- `content.lua` mutates text/image blocks without editor or persistence dependencies.
- `selector.lua` separates `apply` (mutation) from `publish` (lifecycle events);
  `accept` preserves the combined interface for existing callers.
- `permissions.lua` owns permission queues, responses, auto-yes policy, cancellation,
  and exit cleanup. Editor effects are supplied explicitly.
- `permission_view.lua`, `slash_completion.lua`, `prompt.lua`, and `transcript.lua`
  own editor interaction. Transcript animation subscriptions belong to presentation.
- `projection.lua` explicitly selects content fields for history and companion output.

An explicit recovery request never silently creates a new conversation. Failed
loads restore the original cached transcript, tools, and usage. The controller
persists the accepted ID and invokes one-shot resume callbacks before flushing
queued prompts. Cancellation responds to permissions; adapter exit drops callbacks
without responding on a closed connection.

## Dashboard and application adapters

`dashboard/router.lua` routes semantic open/add actions by item kind. The dashboard
supplies callbacks for expansion, navigation, and view-owned state. Domain changes
remain in feature services and the existing repository/document/session action
collaborators. Adding a handler must not introduce filesystem or process work into
`dashboard/model.lua` or `dashboard/view.lua`.

Dashboard snapshots prepare data before model formatting and buffer updates.
Animation refreshes runtime presentation without repeating filesystem discovery.

## Tasks

`tasks/mutations.lua` composes document/query/commit collaborators and operation
families. `tasks/mutations/documents.lua`, `states.lua`, and `recovery.lua` receive
the shared readers, revision guards, and commit functions explicitly. Splitting a
source file does not split a workspace-locked operation into independently saved
writes. Cross-board recovery retains its guarded copy/commit/cleanup sequence.

`tasks/view/save.lua` coordinates editor saves separately from window layout:
snapshot columns and changedticks, parse/diagnose, commit the whole layout, then
reconcile identities and clear modified flags only for unchanged buffers. Native
undo history and externally changed documents remain protected.

## Knowledge and companion

`knowledge.lua` is a compatibility facade over `knowledge/catalog.lua`, with lazy
interactive entry points into `knowledge/ui.lua`. Catalog/source operations do not
load browsing UI. Existing ingestion, research, import, metadata, and agent
collaborators retain their responsibilities.

`companion.lua` composes the process/socket owner in `companion/host.lua` with the
scoped dispatcher in `companion/dispatch.lua`. Prompt capability behavior lives in
`companion/prompt.lua`; existing reference, snapshot, receipt, and lifecycle modules
retain their contracts. Shared epoch, identity, and receipt validation precedes
capability execution. Public lifecycle overrides address the same host table.

## Persistence and verification

External modules read state through `store.workspaces`, `scenes`, `active_scene`,
`session_worktrees`, `worktree_buffer`, `sidebar`, and session query methods.
Writes use existing locked transactions. `store.data` remains available for
compatibility and internal transaction implementation; new feature consumers
should use the focused accessors.

Tests run in isolated Neovim processes. Focused ACP/session tests live under
`tests/unit/`; the runner discovers them recursively and excludes fixtures. See
[`tests/README.md`](../../tests/README.md) for commands. Module-boundary tests
protect lazy presentation loading as well as public facade composition.
