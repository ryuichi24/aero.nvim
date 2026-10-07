# Mobile companion

Aero's responsive web companion creates and resumes **ACP sessions**, manages
sessions and worktrees, and sends follow-up prompts, cancellation requests, and
explicit permission choices. Neovim owns the
agents, transcripts, queues, worktrees, and permissions. **The computer and
Neovim must stay running.** Terminal agents are not supported by this MVP.

In the session logs, use **Prompts** to browse and search your sent prompts.
Select an entry to jump to its message in the transcript. This works in both
normal and fullscreen logs and pauses live scrolling while you review history.
Scroll back to the bottom to resume following new output. Queued prompts appear
in the list after they are sent.

## Installation and startup

### Install from Neovim (recommended)

On a published Aero release, run:

```vim
:Aero companion install
:Aero companion start
```

The installer selects the macOS/Linux ARM64 or AMD64 binary matching the
plugin's root `release.json`, downloads it from the corresponding GitHub Release,
verifies its SHA-256 checksum and reported version, and installs it under
`stdpath("data")/Aero/bin/<version>/`. Startup finds it automatically; no PATH or
`companion.executable` configuration is required. Installation requires `curl`
and either `sha256sum` or `shasum`, but no Go, Node.js, or pnpm.

Installation shows a non-focusable status popup with a spinner, elapsed time,
and the current download, verification, or installation stage. It closes on
success or failure; the final result appears in a notification.

Failed downloads, checksum/version mismatches, or installation errors leave an
existing binary intact. The release must already contain the companion binary
and `SHA256SUMS`; unpublished development revisions require a source build.
After upgrading the plugin, stop the bridge, rerun the install command, and start
it again. Installation itself does not start or restart the bridge.

For a lazy.nvim build hook:

```lua
{
  "ryuichi24/aero.nvim",
  build = function()
    require("aero.companion_install").install()
  end,
  opts = {},
}
```

### Automatic startup

To launch the installed companion automatically when Aero is set up:

```lua
require("aero").setup({
  companion = { auto_start = true },
})
```

`auto_start` defaults to `false`. Startup is scheduled after setup completes and
uses the same pairing popup and error reporting as `:Aero companion start`.
With a lazy-loaded plugin, this happens when the plugin loads. Install the binary
first with `:Aero companion install` or build it from source.

### Manual binary installation

Install the companion on the **computer running Neovim**. The phone uses its
browser; it does not need a separate native app. Tagged Aero releases publish a
single executable with the frontend embedded, so no Go, Node.js, or pnpm is
required at runtime.

Download from [GitHub Releases](https://github.com/ryuichi24/aero.nvim/releases)
using the **same release tag as your installed Aero plugin**:

| Computer | Asset suffix |
| --- | --- |
| macOS, Apple Silicon | `darwin-arm64` |
| macOS, Intel | `darwin-amd64` |
| Linux, ARM64 | `linux-arm64` |
| Linux, x86-64 | `linux-amd64` |

Assets are named `aero-companion-VERSION-OS-ARCH`. Download
`SHA256SUMS` too. In the download directory, verify the selected
file (replace the example version with your release):

```sh
shasum -a 256 aero-companion-0.4.0-darwin-arm64
```

Compare the result with its entry in `SHA256SUMS`, then install:

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 aero-companion-0.4.0-darwin-arm64 "$HOME/.local/bin/aero-companion"
"$HOME/.local/bin/aero-companion" --version
```

Put `~/.local/bin` on Neovim's PATH, or configure the absolute path explicitly:

```lua
require("aero").setup({
  companion = { executable = vim.fn.expand("~/.local/bin/aero-companion") },
})
```

Then follow the startup steps below. To upgrade, stop the companion, replace its
binary with the version matching the upgraded plugin, and start it again.
Windows hosts are not currently supported. Releases also include
`AERO_COMPANION_THIRD_PARTY_LICENSES.tar.gz` with frontend dependency notices.
If your plugin checkout is newer than the available release, build from that
checkout instead.

### Build from source

Requirements to build: Aero installed in Neovim, Go 1.24+, Node.js 22.12+
(Node.js 24 recommended), pnpm 11.22.0, and a Unix host (macOS/Linux).
The pnpm version is pinned in `apps/companion/web/package.json`.
The bridge uses Go's standard
library; the mobile UI uses React with strict TypeScript, Tailwind CSS, and
TanStack Query, built with Vite. A bottom navigation bar provides quick access
to Sessions, Inbox, and Transcript, with safe-area spacing on phones. The
production binary embeds the built UI: **Go, Node.js, pnpm, and Python are not
needed at runtime** once the binary has been built.

From the plugin checkout:

```sh
make build-companion
```

This uses `pnpm install --frozen-lockfile` with the checked-in lockfile, type-checks and builds React,
then compiles `apps/companion/aero-companion` with the assets embedded.
The executable version comes from the root `release.json`, shared with the MCP
adapter and the plugin's release tag. Both Go modules belong to the root
`apps/go.work` workspace; see [host-tool development and releases](releasing.md).

Build the UI
before invoking Go commands directly (`make build-companion-ui`); generated
`web/dist`, `node_modules`, and the binary are ignored by Git. To deploy, copy
the binary to your Aero host and set `companion.executable` to its absolute path.

### Start and pair

1. Start an ACP agent in Aero normally.
2. Run **`:Aero companion start`**. Aero starts the private socket adapter and
   Go web bridge automatically using your `setup().companion` options. A popup
   shows the connection URL and a **six-digit pairing code**; no terminal
   command or log lookup is needed. Repeating start reopens the popup without
   spawning a duplicate process.
3. On the phone, open the popup's URL and enter the six digits once. Previously
   paired phones reconnect automatically, including after bridge, Neovim, or
   browser restarts, as long as their cookie and saved device record remain.

Startup first uses an explicit `companion.executable`, then a local build under
the plugin's `apps/companion/aero-companion`, then the matching installed release,
then `aero-companion` on PATH. Override it with
`companion.executable = "/absolute/path/to/aero-companion"` if needed.
Ordinary startup only requires the Neovim command.
Changing setup options requires stopping/restarting the companion. If upgrading
from a manually started bridge, stop that old terminal process once so the
managed bridge can bind the port. Older in-memory pairings need one new pairing
with this build; subsequent restarts remember them.

The bridge defaults to `127.0.0.1:8765`. `--origin` must match the browser's exact
scheme, hostname, and port (no trailing slash). A different port requires both
`--port PORT` and `--origin http://localhost:PORT`.

### Stopping the companion

Run **`:Aero companion stop`**, or press `s` in the popup, to stop both the
managed web bridge and its socket adapter. `q`/Escape closes only the popup.
Quitting Neovim also stops its managed bridge; losing the parent process closes
the bridge's private control channel and triggers shutdown. Your saved device
records remain on disk. Stopping the companion does not stop ACP agents.

## Pairing and revocation

Pairing codes are cryptographically random **six-digit strings**, including
leading zeros, single-use, expire after five minutes, and allow at most 20
attempts. The phone field opens a numeric keyboard. Each paired phone gets a
separate high-entropy credential, not the six-digit code.

Popup keys: `p` issues a new code, `r` selects a remembered device to revoke,
`y` copies the URL, `s` stops the companion, and `q`/Escape closes the popup.
Commands are also available:

| Neovim command | Action |
| --- | --- |
| `:Aero companion install` | Download and verify the matching release binary |
| `:Aero companion start` | Launch automatically or reopen the pairing popup |
| `:Aero companion pair` | Show a fresh six-digit code for another phone |
| `:Aero companion devices` | Show remembered device names and IDs |
| `:Aero companion revoke` | Select a device to revoke |
| `:Aero companion stop` | Stop the managed bridge and adapter |

Device credentials are stored **only as hashes** in an origin-scoped,
mode-0600 file under `stdpath("data")/Aero/companion`, inside a private directory.
Override the location with `companion.devices_file`; its parent directory must
be private (0700). Writes are atomic and saved before pairing/revocation reports
success. A lock prevents concurrent writers, and unreadable/corrupt stores cause
an explicit startup error rather than silently forgetting paired devices.

The browser receives a persistent HttpOnly, SameSite=Strict cookie, renewed for
one year on authenticated requests; HTTPS cookies also require Secure transport.
Cookie names and storage are scoped to the exact origin so different bridge
ports do not overwrite each other's pairing. Bridge/Neovim restarts do not revoke
devices. Clearing/expiring browser cookies, changing origins, deleting the saved
device file, or using a different browser requires pairing again.

Revocation persists across restarts, rejects subsequent requests, and closes an
active stream at its next poll. The phone's **Unpair** button revokes its own
credential. Local pairing/device controls use the inherited parent-process
channel, not HTTP administration endpoints. Device tokens/hashes are not exposed
in the popup or process logs; only the temporary pairing code is shown locally.

## External SSH tunnel

A PWA/browser cannot establish an SSH tunnel. Establish it with an external
SSH client on the phone (or a client device running the browser):

```sh
ssh -N -L 127.0.0.1:8765:127.0.0.1:8765 user@aero-host
```

Keep the companion bound to localhost on the Aero host. On the device with the
tunnel, browse to `http://localhost:8765` and pair. The SSH client must support
local forwarding and remain running; consult its platform-specific instructions.
This does not require, or expose, a Neovim RPC listener.

## Direct local Wi-Fi or private VPN

By default, direct network connections require explicit binding **and HTTPS**,
even over a private VPN. Supply a certificate valid for the DNS name/IP the phone
uses and trusted by that phone. For example:

```lua
require("aero").setup({
  companion = {
    bind = "192.168.1.20", port = 8765,
    origin = "https://aero-host.example:8765",
    cert = "/path/to/fullchain.pem", key = "/path/to/private-key.pem",
  },
})
```

Then run `:Aero companion start` and use the popup's URL/code.

Use the host's VPN address for `--bind` with a private VPN. Install your private
CA on the phone if using locally issued certificates. The hostname must resolve
to the configured bind address. Non-loopback HTTP is refused unless explicitly
enabled with `companion.allow_http` or `--allow-http`; TLS has a minimum
version of 1.2. Exact Host and Origin checks, SameSite cookies, and Fetch Metadata
checks prevent browser cross-origin actions and stream access. No CORS wildcard
or raw Neovim RPC endpoint is available.

### Tailscale: phone to MacBook

Connect both devices to the same Tailscale tailnet. The companion still requires
HTTPS for direct VPN access by default; use the MacBook's full MagicDNS hostname
and a Tailscale-issued certificate. If your tailnet cannot issue certificates,
see [explicit HTTP over Tailscale](#explicit-http-over-tailscale) below.

1. In the [Tailscale DNS settings](https://console.tailscale.com/admin/dns),
   enable **MagicDNS** and **HTTPS Certificates**. Find the MacBook's full DNS
   name in the admin console, for example `macbook.tail12345.ts.net`.
2. On the MacBook, get its Tailscale IPv4 address:

   ```sh
   tailscale ip -4
   ```

   Replace the addresses and hostnames below with your MacBook's values. Use
   the same full hostname for the certificate, origin, and browser URL.

3. Obtain a certificate on the MacBook, storing it outside the plugin checkout:

   ```sh
   mkdir -p "$HOME/.config/aero-companion/tls"
   tailscale cert \
     --cert-file "$HOME/.config/aero-companion/tls/cert.pem" \
     --key-file "$HOME/.config/aero-companion/tls/key.pem" \
     ryuichis-macbook-air.talic21a44.ts.net
   ```

   If `tailscale` is not on your PATH, check the macOS app's CLI:

   ```sh
   /Applications/Tailscale.app/Contents/MacOS/Tailscale version
   ```

   If that works, use that executable path in place of `tailscale` above.

4. Configure the companion in Neovim (build once if needed):

   ```lua
   require("aero").setup({
     companion = {
        bind = "100.100.100.100", port = 8765,
       origin = "https://ryuichis-macbook-air.talic21a44.ts.net:8765",
       cert = "~/.config/aero-companion/tls/cert.pem",
       key = "~/.config/aero-companion/tls/key.pem",
     },
   })
   ```

   Run **`:Aero companion start`** to launch automatically and display the popup.

5. With Tailscale connected on the phone, open
   configured HTTPS URL in its browser. Enter the popup's six-digit code once.
   If it expires, press `p` in the popup or run `:Aero companion pair`.

Use the **full hostname** in the browser, not the `100.x.x.x` address or a short
machine name: the certificate covers the full hostname. The browser URL must
match `--origin` exactly. Keep the MacBook awake, Neovim running, and the bridge
running while using the phone.

If the phone cannot connect, confirm both devices are online in Tailscale. With
custom tailnet access rules, allow the phone to reach the MacBook on **TCP port
8765**; allow incoming connections for `aero-companion` if macOS prompts.
Certificates obtained as files with `tailscale cert` require periodic renewal;
after renewing the files, restart the bridge to load them. See
[Tailscale's HTTPS documentation](https://tailscale.com/kb/1153/enabling-https)
for certificate setup and renewal details.

#### Explicit HTTP over Tailscale

If Tailscale certificates are unavailable, you can opt in to direct HTTP through
Aero's setup. Replace the example IP with the MacBook's `tailscale ip -4` address:

```lua
require("aero").setup({
  companion = {
    bind = "100.101.102.103",
    port = 8765,
    origin = "http://100.101.102.103:8765",
    allow_http = true,
  },
})
```

Run **`:Aero companion start`**. The Go bridge launches automatically and a
popup displays the URL and six-digit code. No separate terminal command is
needed. Pair once; the phone's browser is remembered for future restarts.

To configure Aero directly when launching Neovim, combine the companion options
with the task-agent options in the same `setup()` call. For a checkout at
`/Users/ryu/dev/personal/projects/aero.nvim`:

```sh
nvim \
  --cmd 'set rtp^=/Users/ryu/dev/personal/projects/aero.nvim' \
  -c 'lua require("aero").setup({ tasks = { agent = { enabled = true, executable = "/Users/ryu/dev/personal/projects/aero.nvim/apps/mcp/aero-mcp" } }, companion = { bind = "100.101.102.103", port = 8765, origin = "http://100.101.102.103:8765", allow_http = true } })' \
  -c 'Aero'
```

Adjust the checkout/executable paths for your installation and replace the IP in
**both** `bind` and `origin` with the MacBook's actual Tailscale address. This
opens Aero with task-agent integration and the companion settings configured.
Then run `:Aero companion start`; the popup handles connection and pairing.

On the phone, with Tailscale connected, open `http://100.101.102.103:8765` and
pair using the popup's code. You may use a MagicDNS hostname instead of the IP
in `origin`, but the browser URL must match it exactly. Binding to the Tailscale
IP limits the listener to that address. Authentication, revocation, and browser
origin checks remain enabled.

##### Public dotfiles repositories

A Tailscale `100.x.x.x` address is private, not your public internet IP.
Publishing it does not grant access to your MacBook: connecting still requires
access to your tailnet and permission under its access rules. It does reveal a
detail about your setup, so you can keep it out of a public Neovim configuration
by reading an environment variable:

```lua
local tailscale_ip = vim.env.AERO_TAILSCALE_IP
if tailscale_ip == "" then tailscale_ip = nil end

require("aero").setup({
  companion = {
    bind = tailscale_ip or "127.0.0.1",
    port = 8765,
    origin = "http://" .. (tailscale_ip or "localhost") .. ":8765",
    allow_http = tailscale_ip ~= nil,
  },
})
```

Set the variable locally with your MacBook's actual Tailscale address, then
launch Neovim from that shell:

```sh
export AERO_TAILSCALE_IP="100.101.102.103"
nvim
```

Add the `companion` table to your existing `setup()` call if you already have
one. Without the variable, this configuration defaults to localhost. Keep the
export in a local, untracked shell configuration if you want it to persist.
Do not publish pairing codes, Tailscale auth keys, TLS private keys, or the
companion's remembered-device file; the Tailscale IP itself is not a credential.

HTTP has no application-level TLS: use this opt-in only over Tailscale or another
trusted private network. Tailscale encrypts the network connection; the browser
still considers the HTTP page an insecure context. Core session controls work,
but HTTPS-only browser features such as PWA installation may be unavailable.
The opt-in defaults to `false` and does not require disabling authentication.

## Workflow and reconnect semantics

- Expand a workspace to **New worktree**. Enter an existing or new branch;
  Aero uses your configured `worktree_path` and creates new branches from HEAD.
- Expand a worktree to **New AI session**, choose a configured ACP agent, and
  optionally name the session. It starts immediately without changing the host's
  focused window. Open a stopped/exited session and choose **Resume session** to
  load its saved conversation using Aero's normal resume behavior.
- Open a session to **Rename session** or **Delete session**. Deletion stops the
  agent and removes Aero's saved history, with an explicit confirmation form.
- **Rename worktree branch** changes the branch name, keeping its checkout path
  and session identities intact. **Delete worktree** removes the checkout and its
  Aero sessions/history; the main worktree cannot be deleted. Git rejects dirty
  checkouts unless you explicitly choose **Force removal**.
- The **Sessions** view groups ACP sessions by **workspace → worktree → session**.
  Expand workspace/worktree cards to browse, or search by workspace, branch,
  path, agent, session name, or status. Counts and waiting badges update live;
  empty worktrees are shown explicitly. Worktrees without known workspace
  metadata appear under **Other worktrees** rather than being omitted.
- The persistent **Sessions / Inbox / Transcript** navigation keeps the phone
  layout focused on one view. Opening a session shows its location breadcrumb;
  **All sessions** returns to its expanded worktree with the selected session
  marked. Disclosure choices survive stream updates. Draft prompts are kept
  separately per conversation while the page is open, so switching sessions
  does not transfer one agent's draft to another.
- Transcripts render Markdown headings, emphasis, lists, tables, task lists,
  links, and syntax-highlighted fenced code. Messages have separate user/agent
  cards; thinking and tool calls are expandable, with readable plans, file
  changes, raw input/output, permission answers, and queued prompts. Streaming
  updates stay in the same message and follow the output only while you are
  reading at the bottom. Raw HTML is not executed and images are shown as
  descriptive labels rather than fetched while browsing.
- Fenced `mermaid` blocks render as diagrams. If an agent wraps a single diagram
  in a `markdown` or `md` code block, Aero automatically previews it with a
  **View source** control. Mixed Markdown examples keep their source visible and
  offer **Preview diagram** (or **Preview diagrams**). Invalid diagrams retain
  their source with a rendering error. Previewing does not modify saved logs.
- Browse sessions or the attention inbox; opening either only reads existing
  state. It does not start/resume an agent, answer permissions, mark an inbox
  item read, or change a ticket state.
- Submit a follow-up. The UI reports `accepted`, `queued`, or an explicit
  rejection. Busy/starting/settings/task-pending chats use Aero's existing queue.
  Accepted means dispatched to the agent, not that the turn completed.
- Choose an explicitly named permission option. Each action targets a session
  key plus a random conversation generation; permissions also target a random
  live-request ID. Replaced/exited/missing conversations and stale permissions
  cannot affect another agent.
- **Cancel turn & queue** uses Aero's existing cancellation semantics, including
  clearing queued prompts and cancelling a pending permission. Accepted means
  the cancellation was requested, not that the backend has stopped yet.
- Type **`/report`** in the follow-up prompt to choose an existing report from
  the session's worktree or enter a new report name. Choosing updates the draft;
  **Send prompt** creates the new Markdown file when requested and sends the
  configured `reports.prompt` instructions with its absolute path to the agent.
  You can also type `/report new <name>` or `/report select <filename.md>`
  directly, with additional instructions on subsequent lines. Existing files
  are never overwritten by creation, and retries reuse the original receipt.
  Other remote slash commands are rejected. Use the dedicated cancellation button.

The bridge polls Neovim every 500 ms for connected streams and sends changed
authoritative snapshots over Server-Sent Events, with an epoch/revision cursor.
Registered workspaces' Git worktree metadata is refreshed at most every five
seconds; session-only worktrees are also included.
The browser replaces session/transcript/inbox state rather than appending replay
events. Every reconnect gets a complete snapshot, including after an HTTP bridge
restart. This avoids displayed duplicates and repairs gaps without depending on
a finite event replay buffer. It is intended for a few personal devices and modest
transcripts; full-snapshot traffic scales with transcript size. Snapshot reads
have a 16 MiB limit and actions a 128 KiB HTTP/private-protocol limit.

Aero's inbox is runtime-only: completed/error events survive web disconnects
while Neovim runs, but are lost across Neovim restarts. Resolved permissions and
forgotten/replaced chats are removed according to Aero's inbox semantics. A
permission resolved locally between polls may never appear remotely. Existing
transcripts are exposed for runtime chats, including exited chats; sessions not
yet loaded in this Neovim instance are listed as stopped without loading history
or starting agents. Aero's normal history persistence remains unchanged.

Each action has a random operation ID. Neovim retains its argument fingerprint
and receipt; identical retries return the original receipt, different arguments
are rejected. Receipts survive HTTP bridge restarts and adapter stop/start within
the same Neovim process. The UI retains an unresolved action in sessionStorage
and offers **Retry identical action** after a dropped response. Authentication
failures also preserve it so re-pairing cannot silently resend under a new ID.
Up to 10,000 receipts are retained; further actions are rejected instead of
evicting old receipts. Neovim restarts lose receipts but also rotate conversation
generations, so old actions are rejected rather than redirected to resumed chats.

Network loss, host shutdown, or a failed host callback can leave an action's
outcome unknown. The UI explicitly reports this, preserves its ID, and disables
new actions until resolved. A persistent `unknown` receipt requires checking the
host; it never means success. Background execution independent of Neovim and
native apps are outside this MVP. The web manifest allows home-screen use where
supported; there is intentionally no service-worker/offline transcript cache.

### Scoped API

All `/api/*` reads and actions require the device cookie except pairing. GET
`/api/snapshot` returns `connected`, `cursor`, `workspaces`, `worktrees`, `sessions`
(with blocks, queue, conversation generation, and optional live permission), and
`inbox`. GET `/api/events` streams that same shape as SSE `data`, with the cursor
as its `id`. POST routes require JSON and the exact configured Origin:

| Route             | JSON fields                                                       |
| ----------------- | ----------------------------------------------------------------- |
| `/api/pair`       | `code`, optional `name`                                           |
| `/api/prompt`     | `operation_id`, `session`, `conversation`, `text`                 |
| `/api/cancel`     | `operation_id`, `session`, `conversation`                         |
| `/api/permission` | `operation_id`, `session`, `conversation`, `permission`, `option` |
| `/api/revoke`     | empty object (revokes the requesting device)                      |
| `/api/session_create` | `operation_id`, `epoch`, `workspace`, `worktree`, `agent`, optional `name` |
| `/api/session_resume` | `operation_id`, `epoch`, `session`, `target` |
| `/api/session_rename` | `operation_id`, `epoch`, `session`, `target`, `name` |
| `/api/session_delete` | `operation_id`, `epoch`, `session`, `target` |
| `/api/worktree_create` | `operation_id`, `epoch`, `workspace`, `branch` |
| `/api/worktree_rename` | `operation_id`, `epoch`, `workspace`, `worktree`, `target`, `name` (branch name) |
| `/api/worktree_delete` | `operation_id`, `epoch`, `workspace`, `worktree`, `target`, optional `force` |

Actions return `{ "result": { "status": "accepted|queued|unknown" } }` or an
explicit error. Unknown transport outcomes use HTTP 503; stale/rejected actions
use 409, missing credentials use 401, and browser-origin failures use 403.
Operation IDs are 16–128 characters; use a fresh UUID for each new action and
retain it unchanged for retries. The private adapter socket is inside a
mode-0700 runtime directory with mode-0600 socket permissions, accessible only to
the host user. It accepts only snapshots and the scoped actions listed above.
Snapshots include the host `epoch`, configured ACP `agents`, and a random session
`target` for lifecycle actions. Session create/resume receipts also include the
session key. Long-running Git actions may return `unknown`; retry the identical
operation to read its eventual receipt without repeating the Git command.

## Verification

From the repository root:

```sh
make test-companion
```

This builds/type-checks React, runs real ACP/Neovim adapter tests, runs Go HTTP
integration tests with the race detector and `go vet`, and runs React interaction
tests with Vitest/Testing Library. Coverage includes authorization/revocation,
browser origin rejection, HTTPS pairing, embedded assets, SSE reconnect/resync,
prompt receipts, queueing, cancellation, explicit permissions, stale targets,
unavailable hosts, and retaining/retrying unknown outcomes through UI remounts.
CLI subprocess tests also verify SIGINT/SIGTERM, raw-terminal Ctrl-C, and `quit`
while an authenticated event stream is active, plus background startup with
closed stdin.
Managed startup tests verify the one-command launcher, six-digit popup,
idempotent start, credential/cookie persistence across restarts, and durable
revocation. Storage tests cover private permissions, hashes rather than tokens,
origin isolation, locking, write failures, and the parent-only control channel.
Installer tests exercise command completion, release/platform selection, real
SHA-256 hashing and executable version checks, temporary-file cleanup, and
preserving the prior binary after failed downloads, checksums, or replacements.
The deterministic ACP test peer in `tests/fixtures/companion_acp.py` requires
Python 3 **for tests only**, following Aero's other ACP fixtures.

For a deterministic local browser check (test peer, not a real agent):

```sh
AERO_COMPANION_BROWSER_FIXTURE=1 go -C apps/companion test -run '^TestBrowserFixture$' -v
```

Open `http://localhost:8765` at 390×844, pair with
`123456`, open **Companion test**, and read the existing
transcript. Send `Hello from phone` and observe partial then completed output.
Open its completed inbox event. Send `permission`, open the permission inbox
event, and select **Allow once** or **Reject once**. This fixture only binds
localhost and uses a deliberately fixed test pairing code. Stop it when finished.
Set `AERO_COMPANION_BROWSER_PORT=18765` alongside the fixture variable if port
8765 is already in use, then open `http://localhost:18765`.
Set `AERO_COMPANION_BROWSER_GROUPS=1` to exercise navigation with two workspace
groups, three worktree directories, and four real fixture ACP sessions.

## Standalone bridge and React development

Normal use only needs `:Aero companion start`. For standalone/debug use, the
low-level Lua adapter `require("aero.companion").start()` returns a socket and
exported settings file without launching a second bridge. Start the executable
with `--config PATH` or explicit `--socket`, `--bind`, `--origin`, etc. flags.
`--devices-file PATH` overrides persistent storage; otherwise standalone mode
uses an origin-scoped file under the OS user configuration directory.

Standalone console commands remain `pair`, `devices`, `revoke DEVICE_ID`, and
`quit`. Ctrl-C/SIGTERM also stop it, including raw-terminal Ctrl-C. Closing stdin
does not stop standalone mode; managed mode deliberately stops when its parent
channel closes. Do not start standalone and managed listeners on the same port.

Build the UI once, then run the Go bridge for the Vite development origin:

```sh
./apps/companion/aero-companion --socket /path/from/neovim/companion.sock \
  --origin http://localhost:5173
```

In a second terminal:

```sh
pnpm --dir apps/companion/web run dev
```

Open `http://localhost:5173`. Vite serves React with hot updates and proxies only
`/api` to the localhost Go listener on port 8765, preserving Host/Origin checks.
Use this localhost setup for development; deployed phones use the Go binary's
embedded production assets and the configured HTTPS/tunnel origin. To inspect
frontend types/tests independently, use `pnpm --dir apps/companion/web run typecheck`
and `pnpm --dir apps/companion/web test`. Rebuild the binary after changing
production assets.
