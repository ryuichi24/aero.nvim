-- Run: nvim --headless -u NONE -l tests/layout_rebalance.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = require("aero.storage").canonical(root)
require("aero.git").list = function()
	return { { path = root, branch = "main" } }
end
require("aero.git").main_root = function()
	return root
end
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	worktree_tabs = false,
	dashboard = { width = 20 },
	panel = { width = 40 },
	layout = { min_code_width = 20 },
	tasks = { directory = "worktree", states = { "todo", "done" } },
})
vim.cmd.runtime("plugin/aero.lua")
local dashboard, panel, layout = require("aero.dashboard"), require("aero.panel"), require("aero.layout")
local ws = require("aero.store").add_workspace(root)
local board = assert(require("aero.tasks").create_board(ws, "Pane recovery"))
local original_code = api.nvim_get_current_win()
dashboard.open()
local dw = api.nvim_get_current_win()
local pw = panel.open()
api.nvim_set_current_win(original_code)
api.nvim_win_close(original_code, false)
vim.wait(100, function()
	return false
end, 10)
assert(
	layout.dashboard_width() == 20 and layout.panel_width() == 40,
	"closing the editor remembered expanded sidebar widths"
)
api.nvim_set_current_win(dw)
for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
	if line:find("Pane recovery", 1, true) then
		api.nvim_win_set_cursor(0, { row, 0 })
		break
	end
end
vim.cmd("Aero board markdown")
local code = api.nvim_get_current_win()
assert(api.nvim_buf_get_name(0) == board.path)
assert(api.nvim_win_get_width(code) >= 20, "recreated middle pane is too narrow")
assert(not vim.wo[code].winfixwidth, "editor inherited fixed dashboard width")
assert(api.nvim_win_get_buf(dw) ~= api.nvim_win_get_buf(code) and panel.win() == pw)
assert(layout.dashboard_width() == 20 and layout.panel_width() == 40, "auto shrink replaced preferred sizes")
-- Preferred sizes return on a larger monitor; narrowed screens still reserve editor space.
vim.o.columns = 140
api.nvim_exec_autocmds("VimResized", {})
assert(vim.wait(2000, function()
	return api.nvim_win_get_width(dw) == 20 and api.nvim_win_get_width(pw) == 40
end, 10))
vim.o.columns = 70
api.nvim_exec_autocmds("VimResized", {})
vim.wait(100, function()
	return false
end, 10)
assert(api.nvim_win_get_width(code) >= 20 and api.nvim_get_current_win() == code)
assert(layout.dashboard_width() == 20 and layout.panel_width() == 40)
require("aero.config").options.layout.min_code_width = 30
layout.rebalance()
assert(api.nvim_win_get_width(code) >= 30, "configured editor minimum was ignored")
-- Buffer contents and extra code splits must survive rebalancing.
api.nvim_buf_set_lines(0, -1, -1, false, { "unsaved board notes" })
local buf, tick = api.nvim_get_current_buf(), api.nvim_buf_get_changedtick(0)
local extra_buf = api.nvim_create_buf(true, false)
local extra_win = api.nvim_open_win(extra_buf, false, { split = "below", win = code })
api.nvim_buf_set_lines(extra_buf, 0, -1, false, { "keep this split" })
layout.rebalance()
assert(vim.bo[buf].modified and api.nvim_buf_get_changedtick(buf) == tick)
assert(api.nvim_get_current_win() == code)
assert(api.nvim_win_is_valid(extra_win) and api.nvim_win_get_buf(extra_win) == extra_buf)
vim.fn.delete(root, "rf")
print(
	"Layout rebalance tests passed (middle-pane recreation, preferred widths, monitor changes, draft/focus preservation)."
)
vim.cmd.qa({ bang = true })
