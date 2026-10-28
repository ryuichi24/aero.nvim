# Companion protocol

The companion has three boundaries: browser HTTP/SSE, Go-to-Lua local socket,
and parent-process stdio control. The task MCP bridge is a separate protocol
(`tasks/bridge.lua` and `apps/mcp`); its credentials and revision requests are
not companion device credentials or conversation tokens.

## Reading map

- Browser stream and parsing: `web/src/connection/`.
- Browser submission and recovery: `web/src/actions/use-companion-actions.ts`.
- Go routing/body validation: `server.go`; pairing: `pairing.go`; SSE: `events.go`.
- Go host requests: `host.go`; immutable/coalesced snapshots: `snapshot_cache.go`.
- Lua host coordination: `lua/aero/companion.lua`; socket framing: `companion/transport.lua`.
- Lua projection: `companion/snapshot.lua` and `acp/projection.lua`.
- Lua receipt registry: `companion/receipts.lua`; lifecycle execution: `companion_lifecycle.lua`.

## HTTP and identity

`POST /api/pair` accepts `{ "code": "123456", "name": "Phone" }`. Pairing sets
a remembered-device cookie. Authenticated APIs also retain exact host/origin
checks. `POST /api/revoke` revokes the current device.

All mutating agent/lifecycle actions require `operation_id` (16–128 characters).
The same ID is reused only with identical arguments. IDs below are illustrative.

| Action | Additional identifying / payload fields |
| --- | --- |
| `prompt` | `session`, `conversation`, `text` (1–65536 bytes) |
| `cancel` | `session`, `conversation` |
| `permission` | `session`, `conversation`, `permission`, `option` |
| `session_create` | `epoch`, `workspace`, `worktree`, `agent`, optional `name` |
| `session_resume`, `session_delete` | `epoch`, `session`, `target` |
| `session_rename` | `epoch`, `session`, `target`, `name` |
| `session_assign_board` | `epoch`, `session`, `target`, `conversation`, `workspace`, `board_id`, explicit `replace` boolean |
| `worktree_create` | `epoch`, `workspace`, `branch` |
| `worktree_rename` | `epoch`, `workspace`, `worktree`, `target`, `name` |
| `worktree_delete` | `epoch`, `workspace`, `worktree`, `target`, optional `force` |

HTTP action paths are `/api/<action>`. Session `id` is the stable registration
key; `target` identifies the current runtime object. `conversation` identifies
the current chat generation, not the agent's external ACP session ID. `epoch`
identifies the current Lua host. These fields prevent acting on stale selections.

`POST /api/submodule_browse` is a read-only discovery request with `epoch`,
`target`, and `worktree`. Without `path`, it returns that checkout's submodule
entries (`name`, absolute `path`, `initialized`). Supply an entry's exact path to
discover its repository's `workspace` and `worktrees`, including lifecycle targets.
`loading: true` means bounded asynchronous discovery is pending; clients may poll
while the section is open. Optional `refresh: true` invalidates discovery caches
before reading. Errors and uninitialized entries do not initialize or clone Git
repositories, and paths not declared in the selected checkout are rejected.

```json
{
  "operation_id": "example-operation-0001",
  "session": "/repo::fixture",
  "conversation": "conversation-example",
  "text": "Review this change."
}
```

## Receipts and retries

Successful HTTP responses contain `result`, for example
`{ "result": { "status": "accepted" } }`. Statuses are:

- `accepted`: the host accepted the action, not necessarily completed the agent turn.
- `queued`: the prompt is retained behind current startup/turn/settings work.
- `unknown`: the operation's result is not yet known, including asynchronous assignment.

The browser saves the pending ID and payload before submission. An interrupted
or invalid response can have an unknown outcome even when the host executed the
action. Retry sends that identical action. A retained matching receipt is returned
without repeating execution. ID reuse with different payloads is rejected.

Lua records `unknown` before side effects; callbacks can replace it with the final
receipt. Receipts live for the Lua host epoch and have a 10,000-entry bound. New
actions are refused at capacity rather than evicting receipts. There is no promise
of recovering an old receipt across host restart. Definitive rejections are shown
separately from network uncertainty.

## Snapshots and SSE

`GET /api/events` emits complete JSON snapshots as SSE `data` and a bridge-owned
cursor as SSE `id`; unchanged snapshots receive heartbeat comments. The browser
treats SSE as authoritative. `GET /api/snapshot` can diagnose lost pairing but
does not compete with the SSE stream as a browser snapshot source.

Required envelope: `connected`, `cursor`, `sessions`, `inbox`, `workspaces`,
`worktrees`. Connected host data also supplies `epoch`, `agents`, `boards`, and
optional companion UI preferences. Go normalizes missing list envelopes when the
host is unavailable, marks the snapshot disconnected, and owns cursor revisions.

Optional `submodules` entries link a parent `worktree` and mount `path`/`name` to
the child repository's `workspace`. These relationships describe discovered mounts,
allowing clients to scope nested repositories and external worktrees without
guessing ownership from filesystem paths.

Session blocks contain protocol/content fields. Typewriter/cache state is excluded;
live permission callbacks are never serialized. Persisted ACP history additionally
marks unanswered permission blocks interrupted, without changing live blocks.

`tests/fixtures/companion-snapshot.json` is the common example checked by the Lua
projection, Go snapshot bridge, and TypeScript parser tests. Browser parsing checks
required nested identity/list fields before handing a snapshot to screens.

## Local socket and process control

Each Go-to-Lua connection sends one newline-delimited
`{ "method": "snapshot", "params": {} }` or allowlisted action. Responses contain
`result` and/or `error`. Requests are bounded at 128 KiB and responses at 16 MiB.
Dispatch is scheduled onto Neovim's editor thread. This is neither arbitrary
evaluation nor Neovim RPC.

Managed companion startup exports private JSON settings and launches the binary
with `--stdio-control`. Parent controls (`pair`, `devices`, `revoke`, `stop`) and
revisioned state events use that private process channel. HTTP clients do not
receive process configuration or device credential material.
