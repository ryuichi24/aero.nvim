# Architecture and reading guide

Aero has three entry points: Neovim (`plugin/aero.lua` and `lua/aero/init.lua`),
the Go companion HTTP bridge (`apps/companion/main.go`), and the task MCP adapter
(`apps/mcp/cmd/aero-mcp/main.go`). Start with the entry point for the feature you
want to understand, then follow its named service rather than the entire UI.

## Module map

| Responsibility | Start here |
| --- | --- |
| Cancel, resume and usage commands | `lua/aero/commands.lua` |
| Focused/prompt/dashboard/panel session precedence | `lua/aero/session_target.lua` |
| Code-window and worktree navigation | `lua/aero/navigation.lua` |
| Worktree review, folder tree, and read-only Git comparisons | `lua/aero/review.lua`, `review/tree.lua`, `review/git.lua` |
| Dashboard loading and actions | `lua/aero/dashboard.lua` |
| Dashboard agent selection, creation, rename and restart | `lua/aero/dashboard/session_actions.lua` |
| Dashboard repository creation, removal, pull and branch workflows | `lua/aero/dashboard/repository_actions.lua` |
| Dashboard reports, references, reading and document mutations | `lua/aero/dashboard/document_actions.lua` |
| Dashboard bindings/help and disposable refresh subscriptions | `lua/aero/dashboard/keymaps.lua`, `subscriptions.lua` |
| Persistent state transactions and cross-process locking | `lua/aero/store.lua`, `state_lock.lua` |
| Session registry and staged terminal/ACP startup | `lua/aero/session.lua` |
| Dashboard snapshot preparation and live session refresh | `lua/aero/dashboard/snapshot.lua` |
| Prepared tree formatting and buffer updates | `lua/aero/dashboard/model.lua`, `view.lua` |
| ACP lifecycle, queue and turn completion | `lua/aero/acp/conversation.lua` |
| Immediate composer commands and stopped-session policy | `lua/aero/acp/local_commands.lua` |
| Incoming notifications and requests | `lua/aero/acp/updates.lua`, `requests.lua` |
| ACP editor effects | `lua/aero/acp/prompt.lua`, `transcript.lua`, `editor_options.lua` |
| Streaming reveal progress and renderer caches | `lua/aero/acp/reveal.lua`, `render.lua` |
| History/wire block projection and record annotations | `lua/aero/acp/projection.lua`, `types.lua` |
| Task reads and new documents | `lua/aero/tasks/query.lua`, `documents.lua` |
| Task mutations and layout validation | `lua/aero/tasks/mutations.lua`, `layout_plan.lua` |
| Placement writes and rollback | `lua/aero/tasks/commit.lua` |
| Retained draft registry | `lua/aero/tasks/drafts.lua` |
| Board editing and presentation | `lua/aero/tasks/view.lua`, `view/columns.lua`, `view/layout.lua`, `view/actions.lua` |
| Companion socket, projection and receipts | `lua/aero/companion/transport.lua`, `snapshot.lua`, `receipts.lua` |
| Go HTTP bridge | `apps/companion/server.go`, `config.go`, `pairing.go`, `events.go`, `assets.go`, `snapshot_cache.go` |
| Browser networking and action recovery | `apps/companion/web/src/connection/`, `actions/` |
| Browser routes, preferences and selectors | `apps/companion/web/src/navigation/`, `preferences/`, `selectors/` |
| Conversation and attention screens | `apps/companion/web/src/conversation/`, `attention/` |

`require("aero.acp")` and `require("aero.tasks")` remain stable facades. Chat
methods also retain their public signatures; editor methods delegate explicitly
instead of assembling a class from multiple mixins.

## Dependency rules

- Commands and protocol adapters call feature services directly.
- Controllers prepare display data; renderers do not start Git or agent processes.
- Services query a narrow draft-status boundary, not board windows.
- Direct calls express commands and queries. Completed-change notifications refresh UI.
- Public module facades retain compatibility; implementation modules own state.
- Conversation state, editor state, persistent records, and wire projections are distinct.

The dashboard controller owns expansion state, repository caches, windows, and
refresh scheduling. `dashboard/snapshot.lua` reads feature services to prepare
expanded sections, receiving controller state and a repository-change callback
explicitly. Its live-session refresh updates the retained snapshot without
rescanning files or task metadata. `dashboard/model.lua` formats that snapshot;
`dashboard/view.lua` applies the result to editor buffers. Public API methods use
`ensure_setup()` for initialization and name their destination feature explicitly.

Dashboard session actions receive the selected item/session explicitly. Creation
notifies the controller before navigation so it can expand the owning worktree;
restart returns the destination window so the controller can retain its target.
These actions do not own dashboard state or resolve the cursor selection.
Repository and document actions follow the same explicit-target/callback boundary;
the controller retains cursor routing, tree expansion and window coordination.
Bindings/help live together, and binding replacement preserves user overrides.

`dashboard.setup()` replaces its subscriptions; `teardown()` disposes them and
invalidates queued refresh work. Completed-change notifications coalesce into one
scheduled render, retaining any repository-reload request in that batch. Direct
user actions can still render immediately. Session and spinner listeners share an
ordered registry with unsubscribe functions and error reporting. The legacy task
`User` event is adapted at the dashboard subscription boundary.

## State ownership

| State | Owner | Lifetime |
| --- | --- | --- |
| Workspace and session definitions | `store.lua`, `state_lock.lua` | Persistent JSON; lock/reload/mutate/replace |
| Live session identity, process and chat | `session.lua` | Current Neovim instance |
| Conversation blocks, queue and permissions | ACP conversation | Current chat; history projection is persisted |
| Transcript layout, render scheduling and decorations | `chat.editor`, ACP editor modules | Current chat/editor lifetime |
| Prompt buffer handles | ACP prompt module | Editor buffers; exposed to session/window coordination |
| Worktree windows and cursor locations | tabs, panel, buffers, layout | Current instance; code locations can be persisted |
| Board and ticket source | task storage | Markdown files, with workspace locks and revision checks |
| Retained board drafts | task draft registry | Includes hidden and closed-tab editing sessions |
| Companion operation receipts and target identities | Lua companion | Current host epoch |
| Device registrations | Go companion device store | Persistent paired devices |
| Browser snapshot | React Query cache | Replaced by authoritative SSE snapshots |
| Browser selection, drafts and pending actions | Companion reducer/action coordinator | Browser session; pending action survives reload |

Display names are not session identities. Rename retains history identity. Saved
conversation IDs can differ from runtime companion target/conversation tokens.

## Walkthroughs

### Open an agent session

Dashboard selection or a picker identifies a worktree/session. Navigation enters
the checkout and chooses a code or panel window. `session.lua` starts or restores
the terminal/ACP backend. The panel presents it; store/history retain definitions
and readable history even when a backend cannot resume.

Session startup validates the agent/window, stops the prior backend, prepares ACP
task/reading integrations, and allocates a replacement buffer. Separate local
`start_acp` and `start_terminal` functions launch each backend. Buffer preparation
provides deferred wipe registration and old-buffer cleanup; each backend invokes
them after accepting the replacement buffer. This keeps backend launch details
out of the startup coordinator while preserving existing lifecycle ordering.

### Send an ACP prompt

Prompt-buffer submission reads the draft and calls the conversation's `prompt`.
Starting/busy/settings-pending conversations queue the prompt. A ready chat sends
`session/prompt` through `acp/client.lua`. Protocol updates modify transcript
blocks; presentation renders them. The response ends the turn and flushes the
next queued prompt. Cancellation clears the queue and resolves live permissions.

`local_commands.lua` handles immediate composer commands before task preparation
or queue gates. Only `/resume`, `/prompt`, and `/export` run while stopped;
other stopped input is consumed with a notification. Immediate commands also
run while busy or task preparation is pending. Dispatch returns a handled flag
separately from the command result, since a nil result still consumes the input.
Model/mode commands remain behind turn readiness checks. A shared `turn_ready`
predicate gates new-ticket preparation and protocol submission; task-pending
input is retained before expansion so it can be prepared after assignment ends.

`conversation.lua` owns starting/ready/exited transitions. `handshake` selects
load/new, `ready` records identity and flushes queued prompts, and `resume_failed`
retains the saved identity/history while exiting the failed backend. `busy` and
model/mode/task pending flags gate turn submission independently of lifecycle
state. Permission requests retain runtime response callbacks; cancellation answers
them and clears the queue before notifying the agent. `transcript.lua` owns the
deferred reveal/render work, while `client.lua` owns protocol/process callbacks.

Streaming byte offsets and pending reveal queues live in `reveal.lua`, keyed by
block/chat identity with weak tables. The renderer owns weak-keyed text and diff
caches, alongside its existing tool-layout cache. Neither reveal advancement nor
formatting writes presentation metadata onto conversation blocks. Export renders
complete text independently of live reveal progress; projection still filters
legacy presentation fields from saved and wire records.
`editor_state.lua` owns access to the chat's explicit `editor` namespace: rendered
lines, marks, option/block locations, sections, pending render/focus work and
spinner decorations. Fold and permission collaborators use that namespace rather
than placing presentation fields alongside protocol state. Lua annotations use
the consistent `aero.*` namespace.

### Save a board

The editor parses all column buffers through `tasks/edit.lua` and submits a layout
with its original baseline. The shared service acquires a workspace lock, reads
the current Markdown, validates revisions, identities and drafts, then prepares
and commits placements/ticket changes. Failures retain the draft and return
rollback/recovery details. Placement is authoritative; ticket state follows it.

### Submit a companion action

The browser persists an operation ID and payload before HTTP submission. Go
authenticates and forwards the scoped action to Lua. Lua checks the operation
fingerprint and target identities, executes a new action, and retains its receipt.
Unknown network outcomes retain the pending action. Retry uses the same ID and
payload so a retained receipt can be returned without duplicate execution. SSE
updates the snapshot independently of action receipts.

See [companion protocol](companion-protocol.md) for field contracts, examples,
receipt lifetime, and the shared Lua/Go/browser fixture.

## Verification and test index

`make test-lua-unit` (or `python3 tests/run.py --unit [names...]`) runs an explicit
set of isolated module tests with Python and Neovim only. It does not check for
Git, `yq`, host binaries, Node.js, or Go. The allowlist in `tests/run.py` documents
which tests meet this contract; new integration-dependent tests stay in the full
lane. Module coverage includes command policy, streaming, subscriptions, listener
lifetimes and concurrent state transactions using child Neovim processes.

`make test-lua` builds the host tools and runs each top-level Lua test in a separate
Neovim process. Prerequisites: Neovim 0.11+, Git, Python 3, Mike Farah's `yq` v4,
Go, Node.js and pnpm. The real image integration test also needs ImageMagick and
image.nvim (`AERO_IMAGE_NVIM=/path/to/image.nvim`, or the default optional pack
location). CI installs a pinned image.nvim revision. `make check-all` includes
this suite and Go/browser checks.

For focused work, after building host tools:

```sh
python3 tests/run.py dashboard_tabs cancel usage
python3 tests/run.py tasks tasks_view tasks_removed
python3 tests/run.py --real-agent opencode
pnpm --dir apps/companion/web test
pnpm --dir apps/companion/web run typecheck
go -C apps/companion test -race ./...
```

The optional OpenCode smoke test uses a real CLI and is excluded by default.
Fixtures under `tests/fixtures/` are agent/host helpers, not runnable suite cases.

| Feature | Lua test families |
| --- | --- |
| Dashboard and navigation | `dashboard_*`, `workspace_pickers`, `worktree_*`, `pull` |
| Worktree review and feedback | `review` |
| Session identity and recovery | `session_creation`, `rename`, `persistence`, `recovery`, `terminal_exit` |
| ACP conversation and presentation | `transcript`, `cancel`, `models`, `modes`, `usage`, `images`, `todos`, `todo_notifications` |
| Draft input and quoting | `prompt_*`, `input`, `quote*`, `prompts` |
| Layout | `fullscreen`, `layout_rebalance`, `pane_resize`, `panel_resize` |
| Reports and exports | `reports*`, `exports`, `mermaid*` |
| Markdown task rules and editor | `tasks`, `tasks_markdown`, `tasks_storage`, `tasks_edit`, `tasks_view`, `tasks_removed*`, `tasks_new_rows`, `tasks_resize`, `tasks_cmdwin` |
| Task-agent integration | `tasks_agent*`, `tasks_bridge`, `tasks_existing_session`, `tasks_stopped_session`, `tasks_new_ticket_prompt`, `tasks_install` |
| Companion | `companion*` |

Web tests live beside their components and Go tests beside host-tool code. Tests
for concurrency, draft conflicts, rollback and uncertain outcomes are the main
behavioral guardrails for architecture changes.
