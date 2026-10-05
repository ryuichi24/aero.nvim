-- Run: nvim --headless -u NONE -l tests/workspace_pickers.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(dir, "p")
local function git(...)
	local result = vim.system({ "git", ... }, { text = true }):wait()
	assert(result.code == 0, result.stderr)
end
for _, name in ipairs({ "alpha", "beta" }) do
	git("init", "-b", "main", dir .. "/" .. name)
	git(
		"-C",
		dir .. "/" .. name,
		"-c",
		"user.name=Aero Test",
		"-c",
		"user.email=test@example.com",
		"commit",
		"--allow-empty",
		"-m",
		"initial"
	)
end
git("-C", dir .. "/alpha", "worktree", "add", "-b", "feature", dir .. "/alpha-feature")
local aero = require("aero")
aero.setup({ state_file = dir .. "/state.json", animation = false })
vim.cmd.runtime("plugin/aero.lua")
local store = require("aero.store")
store.add_workspace(dir .. "/beta")
store.add_workspace(dir .. "/alpha")
local function results()
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if api.nvim_win_get_config(win).focusable == false then
			return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), win
		end
	end
end
local function key(keyname, mode)
	vim.fn.maparg(keyname, mode or "n", false, true).callback()
end
local function filter(query)
	api.nvim_buf_set_lines(0, 0, -1, false, { query })
	api.nvim_exec_autocmds("TextChangedI", { buffer = api.nvim_get_current_buf() })
end
vim.cmd("Aero worktrees")
local search = api.nvim_get_current_buf()
local lines, win = results()
assert(#lines == 6 and lines[1]:find("alpha") and lines[5]:find("beta"))
assert(lines[2]:find("main") and lines[3]:find("feature") and lines[6]:find("main"))
key("j")
assert(api.nvim_win_get_cursor(win)[1] == 3)
key("j")
assert(api.nvim_win_get_cursor(win)[1] == 6, "navigation did not skip workspace heading")
filter("alpha feature")
assert(#results() == 2 and results()[2]:find("feature"))
key("<CR>")
assert(vim.fn.resolve(vim.fn.getcwd()) == dir .. "/alpha-feature")
assert(not api.nvim_buf_is_valid(search))
local tab = api.nvim_get_current_tabpage()
aero.worktrees()
filter("alpha feature")
key("<CR>")
assert(api.nvim_get_current_tabpage() == tab, "existing worktree tab was not reused")
vim.cmd("Aero workspaces")
lines = results()
assert(#lines == 2 and lines[1]:find("alpha") and lines[2]:find("beta"))
key("j")
key("<CR>")
assert(vim.fn.resolve(vim.fn.getcwd()) == dir .. "/beta", "workspace did not open its root checkout")
-- Switching popup types closes the previous one.
aero.workspaces()
search = api.nvim_get_current_buf()
aero.worktrees()
assert(not api.nvim_buf_is_valid(search))
filter("no-such-worktree")
assert(results()[1] == "No matching worktrees")
key("<CR>")
assert(api.nvim_buf_is_valid(api.nvim_get_current_buf()), "empty selection closed picker")
key("q")
assert(not results(), "q did not close picker")
-- The APIs share the same behavior with worktree tabs disabled.
require("aero.config").options.worktree_tabs = false
aero.workspaces()
filter("alpha")
tab = api.nvim_get_current_tabpage()
key("<CR>")
assert(api.nvim_get_current_tabpage() == tab and vim.fn.resolve(vim.fn.getcwd()) == dir .. "/alpha")
store.data.workspaces = {}
vim.fn.delete(dir .. "/state.json")
aero.workspaces()
assert(not results(), "empty workspace list opened a picker")
vim.fn.delete(dir, "rf")
print("workspace pickers: ok")
vim.cmd.qa({ bang = true })
