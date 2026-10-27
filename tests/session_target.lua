-- Run: nvim --headless -u NONE -l tests/session_target.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
require("aero").setup({ state_file = dir .. "/state.json", animation = false })
local sessions = require("aero.session")
local target = require("aero.session_target")
local panel = require("aero.panel")
local focused = assert(sessions.create(dir, "claude", "focused"))
local shown = assert(sessions.create(dir, "claude", "shown"))
local in_dashboard, item = false, nil
target.set_dashboard_selection(function()
	return in_dashboard, item
end)
panel.current_session = function()
	return shown
end
local original_win = panel.win
local panel_buffer = api.nvim_create_buf(false, true)
vim.b[panel_buffer].aero_session = shown.key
local panel_window = api.nvim_open_win(panel_buffer, false, { split = "right" })
panel.win = function()
	return panel_window
end
local buf = api.nvim_get_current_buf()
vim.b[buf].aero_session = focused.key

assert(target.resolve("cancel") == focused, "focused session must precede panel")

vim.b[buf].aero_session = nil
vim.b[buf].aero_chat_key = focused.key

assert(target.resolve("viewed") == focused, "prompt buffer must resolve by chat key")

vim.b[buf].aero_chat_key = nil

assert(target.resolve("cancel") == shown)

in_dashboard, item = true, { session = focused }

assert(target.resolve("cancel") == focused)

item = { wt = { path = dir } }

assert(target.resolve("cancel") == nil, "cancel must not fall back from a worktree row")
assert(target.resolve("viewed") == shown, "viewed policy uses selected worktree's panel session")
assert(target.resolve("resume") == shown, "resume uses the visible panel buffer")

item = { ws = { root = dir } }

assert(target.resolve("viewed") == nil, "workspace row must not target an unrelated session")

panel.win = original_win
api.nvim_win_close(panel_window, true)
vim.fn.delete(dir, "rf")
print("Session-target policies passed (focused, prompt, row, panel and worktree fallbacks).")
