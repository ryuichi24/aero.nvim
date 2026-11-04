# Worktree browser (experimental)

Open a shared Chromium browser in the **Browser** reader slot. Each worktree has
its own browser instance and multiple page tabs. Switching reader slots or
worktrees retains the running browser. Browser processes and page registrations
are runtime-only; Aero does not restore them after restarting Neovim.

[Back to README](../README.md)

## Requirements

- Install [terminal-browser](https://github.com/zenbu-labs/terminal-browser) and run
  its initial setup outside Neovim. Use a build with the `PIXEL_EMBED` embedding
  protocol and the `ls --all --json` / targeted `action` interfaces.
- Run Neovim in a local terminal supporting Kitty graphics and Unicode image
  placeholders, with true-color rendering enabled (`:set termguicolors`).
- Match the configured cell dimensions to your terminal font's pixel dimensions.
  Incorrect dimensions can cause scaling or clipping. Terminal font changes
  require stopping and reopening the browser with updated dimensions.

If the executable is missing, the Browser slot displays a setup page with the
platform's installation command. Press `Y` to copy it, `O` to open the upstream
instructions, and `R` to retry detection after installation. Retry works without
restarting Neovim. If the installed binary is outside Neovim's inherited `PATH`,
configure an absolute path in `browser.cmd` and retry.

Aero checks the executable's advertised embedding capability before launch. A
build without that capability displays upgrade/setup guidance. Startup failures
retain available stderr details in the setup page and health report.

Run `:checkhealth aero` to see the resolved executable path, embedding capability,
and the current worktree's last startup failure. These checks do not verify live
graphics or keyboard behavior.

This integration uses upstream's embedding socket, not graphics escape sequences
inside an ordinary terminal subprocess. Neovim displays image placeholders in a
virtual terminal buffer; terminal-browser sends the image data to the enclosing
terminal. Remote UIs, SSH, and multiplexer passthrough are not verified by this
initial integration. Live rendering and keyboard behavior require testing with
your terminal/browser build; automated tests exercise the socket protocol using
a local fixture rather than Chromium.

```lua
require("aero").setup({
  browser = {
    cmd = { "terminal-browser" },
    cell_width = 10,
    cell_height = 20,
  },
})
```

## Open and navigate

Select an Aero worktree first, then use:

| Command | Action |
| --- | --- |
| `:Aero reader browser` | Show or lazily start this worktree's browser |
| `:Aero browser` | Show this worktree's browser |
| `:Aero browser open http://localhost:3000` | Open an application |
| `:Aero browser open ./mockup.html` | Open a local HTML file, relative to the worktree |
| `:Aero browser next` / `prev` | Switch browser page tabs without a mouse |
| `:Aero browser pages` | Pick a page using Neovim's selection UI |
| `:Aero browser attach` | Choose a page and add its explicit target to an agent draft |
| `:Aero browser stop` | Stop only this worktree's browser |

The first open starts the browser at the requested address. Subsequent opens add
page tabs in the existing instance. URLs need a scheme, such as `http://` or
`https://`. Escape spaces in local paths as for other Neovim command arguments.

Press `i` to enter browser input, and use `<C-\><C-n>` to return to Neovim's
terminal-normal mode. Ctrl-Tab and Ctrl-Shift-Tab are mapped to browser page
navigation in input mode; the enclosing terminal must deliver these as distinct
keys. The `next`, `prev`, and `pages` commands provide keyboard navigation without
depending on those terminal shortcuts. Native browser shortcuts otherwise depend
on what Neovim forwards through its virtual terminal.

Use `:Aero fullscreen` in normal mode to expand the browser. The Browser slot also
participates in reader panes mode. Hiding the slot keeps the browser alive;
stopping it or exiting Neovim closes the corresponding session. Reopening after
stopping starts a new browser.

## Agent access

### MCP tools for ACP agents (opt-in)

Enable the browser tool set before starting or resuming an ACP agent:

```lua
require("aero").setup({
  browser = { agent = { enabled = true } },
})
```

This registers an `aero-browser` server using Aero's shared `aero-mcp` executable.
Install it through `:Aero mcp install`, or use `make build-mcp` in a development
checkout. The executable must include the `browser` tool set. Terminal-browser
itself does not need to be installed to register these tools: a missing dependency
is reported to the agent when it attempts a browser operation.

| Tool | Purpose |
| --- | --- |
| `aero_browser_open` | Open a URL/HTML file and wait for a usable page target |
| `aero_browser_pages` | List this session's worktree pages |
| `aero_browser_action` | Snapshot, screenshot, click, fill, press, scroll, or wait for text |
| `aero_browser_done` | Clear the browser's agent-control indicator |

Open and pages return opaque `page_id` values. Actions require an explicit page ID
and reject IDs from another worktree or an earlier browser instance. Worktree
scope comes from the session binding, not agent-supplied paths or browser keys.
Opening a browser through MCP does not switch tabs or take editor focus; select
the Browser reader slot when you want to watch it.

If the dependency is missing, the MCP tool result is marked as an error with
structured `code`, `message`, `installation_url`, `suggested_command`, and
`next_step` fields. The agent can explain installation and retry afterward.
Browser-only credentials cannot invoke task or knowledge methods.

Screenshots return MCP image content, so adapters that forward images can expose
them to the agent and Aero transcript. Individual PNGs are limited to 512 KB by
the current bridge transport; oversized screenshots return an explicit error.
Snapshot output is bounded and reports truncation. Actions time out after ten
seconds; they do not expose arbitrary shell commands or JavaScript evaluation.

### CLI target attachment

Start a terminal or ACP agent in the same worktree, then run
`:Aero browser attach`. Choose a page and a recipient agent. Aero appends an
instruction to the draft without submitting it, including a command like:

```sh
terminal-browser action --browser <browser-key> --tab <page-id> -- snapshot
```

The agent uses its own command-execution tool for subsequent browser actions.
Aero supplies both browser and page identifiers: changing the visible page or
switching worktrees does not redirect that command. Reattach after stopping the
browser or replacing a page, since the old identifiers no longer apply. This is
an explicit target instruction, not an enforced agent sandbox or a new MCP tool.

Browser instances/page tabs may share cookies and login state according to
terminal-browser's own profile behavior; worktree targeting does not create
separate authentication profiles.

## Document previews

Local HTML files can be opened directly. Files requiring an HTTP origin should
be served by the project's development server. Markdown-to-HTML report previews
and automatic document refresh are follow-up features; the Reports reader slot
continues to provide the editable Markdown source.
