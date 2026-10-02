-- Run from the repository root: nvim --headless -u NONE -l tests/dashboard_mouse.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/main", "p")
vim.fn.mkdir(dir .. "/feature", "p")
dir = vim.fn.resolve(dir)
local main, feature = dir .. "/main", dir .. "/feature"
local file = feature .. "/code.lua"
vim.fn.writefile({ "remembered code" }, file)
require("aero.git").list = function()
	return { { path = main, branch = "main" }, { path = feature, branch = "feature" } }
end
local aero = require("aero")
aero.setup({ state_file = dir .. "/state.json", animation = false, start_insert = false })
require("aero.store").add_workspace(main)
vim.o.mouse = "a"
aero.open()
local dashboard = api.nvim_get_current_buf()
local dashboard_win = api.nvim_get_current_win()
local function mapping(key)
	return vim.fn.maparg(key, "n", false, true)
end
assert(type(mapping("<C-LeftMouse>").callback) == "function")
local mouse = { winid = 0, line = 0 }
vim.fn.getmousepos = function()
	return mouse
end
for _, position in ipairs({ { winid = 0, line = 5 }, { winid = dashboard_win, line = 1 } }) do
	mouse = position
	mapping("<C-LeftMouse>").callback()
	assert(api.nvim_get_current_buf() == dashboard, "click outside a tree row opened a worktree")
end
local function click(line, key)
	api.nvim_set_current_win(dashboard_win)
	api.nvim_win_set_cursor(dashboard_win, { 3, 0 })
	mouse = { winid = dashboard_win, line = line }
	mapping(key).callback()
end
-- The cursor is on the workspace: the action must use the mouse's worktree row.
click(5, "<C-LeftMouse>")
assert(vim.wait(1000, function()
	return vim.t.aero_worktree == feature and api.nvim_get_current_buf() ~= dashboard
end, 10), "Ctrl-click did not open the clicked worktree")
assert(vim.fn.getcwd() == feature)
assert(api.nvim_buf_get_name(0) == feature, "new worktree did not open its directory")
assert(#require("aero.session").all() == 0, "mouse open started an agent")
vim.cmd.edit(vim.fn.fnameescape(file))
local code_buf = api.nvim_get_current_buf()
aero.open_worktree(main)
aero.open()
dashboard_win = api.nvim_get_current_win()
click(5, "<C-LeftMouse>")
assert(vim.wait(1000, function()
	return api.nvim_get_current_buf() == code_buf
end, 10), "Ctrl-click did not restore the remembered code buffer")

-- Ctrl-Enter uses the selected row, independently of the last mouse position.
aero.open()
dashboard_win = api.nvim_get_current_win()
api.nvim_win_set_cursor(dashboard_win, { 4, 0 })
assert(type(mapping("<C-CR>").callback) == "function")
mapping("<C-CR>").callback()
assert(vim.t.aero_worktree == main and api.nvim_get_current_buf() ~= dashboard,
	"Ctrl-Enter did not open the selected worktree")

-- Reconfigure the existing dashboard: new mappings must apply without a restart.
aero.setup({
	state_file = dir .. "/state.json",
	animation = false,
	keymaps = { edit_mouse = "<S-LeftMouse>", edit_enter = "g<CR>" },
})
aero.open()
dashboard = api.nvim_get_current_buf()
dashboard_win = api.nvim_get_current_win()
assert(mapping("<C-LeftMouse>").buffer ~= 1, "default chord survived customization")
assert(type(mapping("<S-LeftMouse>").callback) == "function")
assert(mapping("<C-CR>").buffer ~= 1, "default Enter chord survived customization")
assert(type(mapping("g<CR>").callback) == "function")
api.nvim_win_set_cursor(dashboard_win, { 5, 0 })
mapping("g<CR>").callback()
assert(vim.t.aero_worktree == feature and api.nvim_get_current_buf() == code_buf,
	"reconfigured Enter sequence did not open the selected worktree")
aero.open()
dashboard_win = api.nvim_get_current_win()
click(4, "<S-LeftMouse>")
assert(vim.wait(1000, function()
	return vim.t.aero_worktree == main and api.nvim_get_current_buf() ~= dashboard
end, 10), "custom mouse chord did not open the clicked worktree")

aero.setup({ state_file = dir .. "/state.json", animation = false, keymaps = { edit_mouse = false, edit_enter = false } })
aero.open()
assert(mapping("<C-LeftMouse>").buffer ~= 1, "disabled mouse chord remains mapped")
assert(mapping("<S-LeftMouse>").buffer ~= 1, "custom mouse chord remains mapped")
assert(mapping("<C-CR>").buffer ~= 1, "disabled Enter chord remains mapped")
assert(mapping("g<CR>").buffer ~= 1, "custom Enter sequence remains mapped")
require("aero.buffers").flush()
vim.fn.delete(dir, "rf")
print("Dashboard mouse tests passed (clicked row, directory, restored buffer, custom chord, disabled mapping).")
