vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(dir .. "/repo", "p")
local repo = dir .. "/repo"
assert(vim.system({ "git", "init", repo }, { text = true }):wait().code == 0)
local aero = require("aero")
aero.setup({ state_file = dir .. "/state.json", animation = false, companion = { auto_start = false } })
require("aero.store").add_workspace(repo)
local original_tab = api.nvim_get_current_tabpage()
local editor = api.nvim_get_current_win()
local startup = api.nvim_get_current_buf()
api.nvim_buf_set_name(startup, dir .. "/startup.txt")
api.nvim_buf_set_lines(startup, 0, -1, false, { "keep startup edits" })
local browsed = {}
package.preload["oil"] = function()
	return {
		open = function(path)
			browsed[#browsed + 1] = { path = path, win = api.nvim_get_current_win() }
			local buf = api.nvim_create_buf(false, true)
			api.nvim_set_current_buf(buf)
			vim.bo[buf].filetype = "oil"
		end,
	}
end
aero.open()
local sidebar = api.nvim_get_current_win()
local panel = require("aero.panel").open()
local function browse()
	api.nvim_set_current_win(sidebar)
	local lines = api.nvim_buf_get_lines(0, 0, -1, false)
	for row, line in ipairs(lines) do
		if line:find("repo", 1, true) then
			api.nvim_win_set_cursor(sidebar, { row, 0 })
			break
		end
	end
	for _, map in ipairs(api.nvim_buf_get_keymap(0, "n")) do
		if map.lhs == "e" then
			map.callback()
			return
		end
	end
	error("sidebar e mapping missing")
end
browse()
assert(api.nvim_get_current_tabpage() == original_tab, "e abandoned the initial editor tab")
assert(api.nvim_get_current_win() == editor, "e did not reuse the initial editor")
assert(vim.t.aero_worktree == repo)
assert(browsed[#browsed].path == repo and browsed[#browsed].win == editor)
assert(api.nvim_win_is_valid(sidebar) and api.nvim_win_is_valid(panel))
assert(#api.nvim_tabpage_list_wins(0) == 3, "e created an extra middle window")
assert(api.nvim_buf_get_lines(startup, 0, -1, false)[1] == "keep startup edits")
assert(vim.bo[startup].modified, "startup edits were lost")
aero.close()
aero.open()
sidebar = api.nvim_get_current_win()
browse()
assert(api.nvim_get_current_win() == editor)
assert(#api.nvim_tabpage_list_wins(0) == 3, "repeated e duplicated the editor")
assert(vim.bo[api.nvim_win_get_buf(sidebar)].filetype == "Aero", "e replaced the sidebar")

-- Browsing another checkout keeps the visible sidebar; picker-style navigation
-- from a hidden sidebar must still leave it hidden in newly created tabs.
vim.fn.mkdir(dir .. "/other", "p")
require("aero.navigation").browse_worktree(dir .. "/other")
assert(api.nvim_get_current_tabpage() ~= original_tab)
local sidebars = 0
for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
	if vim.bo[api.nvim_win_get_buf(win)].filetype == "Aero" then
		sidebars = sidebars + 1
	end
end
assert(sidebars == 1 and #api.nvim_tabpage_list_wins(0) == 2, "browsing lost the sidebar or duplicated the editor")
aero.close()
vim.fn.mkdir(dir .. "/hidden", "p")
aero.open_worktree(dir .. "/hidden")
assert(#api.nvim_tabpage_list_wins(0) == 1, "navigation reopened a hidden sidebar")
vim.fn.delete(dir, "rf")
print("sidebar browse: ok")
vim.cmd("qa!")
