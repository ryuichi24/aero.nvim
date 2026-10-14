-- Run: nvim --headless -u NONE -l tests/dashboard_collapse.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local aero = require("aero")
aero.setup({ state_file = dir .. "/state.json", animation = false })
vim.cmd.runtime("plugin/aero.lua")
local store = require("aero.store")
store.data.workspaces = {
	{ root = dir .. "/one", name = "One", expanded = true },
	{ root = dir .. "/two", name = "Two", expanded = false },
}
require("aero.git").list = function(root)
	return { { path = root, branch = "main" } }
end
require("aero.git").remote_status = function() end
require("aero.session").list = function() return {} end
require("aero.exports").list = function() return { { name = "Saved log", path = dir .. "/log" } } end
require("aero.reports").list = function() return { { name = "Saved report", path = dir .. "/report" } } end
require("aero.tasks").list = function() return {}, {} end
require("aero.tasks").list_removed = function() return {} end
aero.open()
local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local function line(text)
	for i, value in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if value:find(text, 1, true) then return i, value end
	end
end
local function expand(text)
	api.nvim_win_set_cursor(win, { assert(line(text)), 0 })
	for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
		if map.lhs == "l" then map.callback(); return end
	end
	error("missing expand mapping")
end
expand("main")
assert(line("Saved log") and line("Saved report"))
vim.cmd("Aero collapse reports")
assert(not line("Saved report") and line("Saved log"))
vim.cmd("Aero collapse exports")
assert(not line("Saved log"))
vim.cmd("Aero collapse boards")
assert(select(2, line("Boards")):find("▸", 1, true))
vim.cmd("Aero collapse worktrees")
assert(not line("Reports") and line("main"))
expand("main")
assert(not line("Saved log") and not line("Saved report"))
local code = api.nvim_create_buf(true, false)
local other = api.nvim_open_win(code, true, { split = "right", win = win })
vim.cmd("Aero collapse")
assert(api.nvim_get_current_win() == other, "collapse changed focus")
assert(not line("main") and not store.data.workspaces[1].expanded)
api.nvim_set_current_win(win)
expand("One")
assert(select(2, line("main")):find("▸", 1, true))
assert(select(2, line("Boards")):find("▸", 1, true))
expand("Two")
api.nvim_win_set_cursor(win, { assert(line("Two")) + 1, 0 })
for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
	if map.lhs == "l" then map.callback() end
end
local lines = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
assert(not lines:find("Saved log", 1, true) and not lines:find("Saved report", 1, true),
	"hidden descendants were not collapsed")
vim.cmd("Aero collapse workspaces")
assert(not line("main"))
local completions = vim.fn.getcompletion("Aero collapse ", "cmdline")
assert(#completions == 6 and vim.tbl_contains(completions, "exports"))
aero.close()
require("aero.buffers").flush()
vim.fn.delete(dir, "rf")
print("Dashboard collapse tests passed (per-type, all, hidden descendants, focus, completion).")
