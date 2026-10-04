# Lifecycle hooks and integrations

Subscribe to Aero operations from Lua or Neovim User autocmds.

[Back to README](../README.md)

## Oil integration

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

`worktree_created` fires after successful Git creation and the completion callback's
refresh. `open_worktree(path, opener)` enters the tab and focuses code before calling
the opener, protecting dashboard/agent windows. Without an opener it restores the
last code buffer, falling back to the directory. Explicit openers take precedence.

## Subscriptions

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
-- Or aero.off(event_name, original_callback)
```

Handlers receive a table including `event`. They run in registration order on Neovim's
main thread, each with its own data copy; errors do not stop remaining Lua handlers.
`"*"` subscribes to all events. Setup entries accept a function or function list.
Repeated `setup()` replaces configured handlers but preserves `on()` subscriptions.

## Events

Session metadata includes `key`, `name`, `agent`, `worktree`, and `buf` when available.

| Event | Additional data / timing |
| --- | --- |
| `setup` | Setup completed |
| `workspace_added`, `workspace_removed` | `root`, `name`; registry updated |
| `worktree_created` | `root`, `path`, `branch`; creation/callback completed |
| `worktree_removed` | `root`, `path`, `force`; removal/callback completed |
| `worktree_entered` | `path`, `tab`, `created`; tab entered |
| `session_created` | Session registered |
| `session_started` | `win`, `type`, `resume`; backend launched (`resume` is requested behavior) |
| `session_ready` | ACP: `session_id`, `type`, `resumed`; initialization/load succeeded |
| `session_resume_failed` | ACP: `session_id`, `type`, full `error`; saved conversation retained |
| `session_model_changed` | ACP: `session_id`, `model_id`, `model_name`, `previous_model_id` |
| `session_mode_changed` | ACP: `session_id`, `mode_id`, `mode_name`, `previous_mode_id` |
| `session_shown` | `win`; session shown/reused |
| `session_stopped` | Backend stop requested |
| `session_exited` | `exit_code`, `type`; current backend exited |
| `session_deleted` | Registration/history deleted |
| `dashboard_opened`, `dashboard_closed` | `win`, `buf`, `tab` |
| `panel_opened`, `panel_closed` | `win`, `tab` |
| `terminal_opened` | `worktree`, `win`, `buf`, `fresh` (new process) |
| `terminal_closed` | `worktree`, `win`, `buf`; hidden, process continues |
| `fullscreen_entered` | `kind`, `tab`, `source_tab`, `win`, `source_win`, `buf` |
| `fullscreen_exited` | `kind`, `tab`, `win`, `buf`; includes manual fullscreen-tab closure |

These describe Aero operations, not external Git worktree creation.

## User autocmds and statusline

Events use PascalCase names prefixed with `Aero`; payloads are in `event.data`:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "AeroWorktreeCreated",
  callback = function(event)
    vim.notify("Created " .. event.data.path)
  end,
})
```

`require("aero").statusline()` returns a compact summary such as `?1 ◐2 ●1`
(waiting / busy / idle).
