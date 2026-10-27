-- Run from the repository root: nvim --headless -u NONE -l tests/reader_navigation.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/first", "p")
vim.fn.mkdir(dir .. "/second", "p")
require("aero").setup({
	state_file = dir .. "/state.json",
	companion = { auto_start = false },
	animation = false,
})
local navigation = require("aero.navigation")
local reader = require("aero.reader")
local config = require("aero.config")
local first, second = dir .. "/first", dir .. "/second"

for _, use_tabs in ipairs({ true, false }) do
	config.options.worktree_tabs = use_tabs
	local win = navigation.open_worktree(first)
	local source = api.nvim_win_get_buf(win)
	reader.select("reports")
	local report = api.nvim_get_current_buf()
	local lines = {}

	for i = 1, 100 do
		lines[i] = "Report line " .. i
	end

	api.nvim_buf_set_lines(report, 0, -1, false, lines)
	api.nvim_win_set_cursor(0, { 60, 0 })
	vim.cmd("normal! zt")
	local view = vim.fn.winsaveview()
	navigation.open_worktree(second)
	reader.select("references")
	local reference = api.nvim_get_current_buf()
	api.nvim_buf_set_lines(reference, 0, -1, false, { "Reference draft" })
	win = navigation.open_worktree(first)

	assert(reader.active() == "reports", "returning to a worktree reset its reader tab")
	assert(api.nvim_win_get_buf(win) == report, "returning replaced the report buffer")
	assert(api.nvim_win_get_cursor(win)[1] == 60, "returning lost the report cursor")
	assert(vim.fn.winsaveview().topline == view.topline, "returning lost the report scroll position")

	reader.select("source")

	assert(api.nvim_get_current_buf() == source, "returning overwrote the source slot")

	reader.select("reports")
	navigation.open_worktree(second)

	assert(reader.active() == "references", "worktrees shared their selected reader tab")
	assert(api.nvim_get_current_buf() == reference, "returning lost the reference draft")

	-- Explicit directory browsing still selects Source.
	navigation.browse_worktree(first)

	assert(reader.active() == "source", "explicit browsing did not select Source")
	assert(api.nvim_get_current_buf() ~= report, "explicit browsing overwrote the report")
end

vim.fn.delete(dir, "rf")
print("reader navigation: ok")
vim.cmd("qa!")
