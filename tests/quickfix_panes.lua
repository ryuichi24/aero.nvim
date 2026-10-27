-- Run: nvim --headless -u NONE -l tests/quickfix_panes.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local layout = require("aero.layout")
local editor = api.nvim_get_current_win()
local first, second = api.nvim_create_buf(true, false), api.nvim_create_buf(true, false)
vim.fn.setqflist({ { bufnr = first, lnum = 1 }, { bufnr = second, lnum = 1 } })

for _, kind in ipairs({ "panel", "prompt", "terminal", "dashboard" }) do
	api.nvim_set_current_win(editor)
	vim.cmd.vsplit()
	local pane = api.nvim_get_current_win()
	local buf = api.nvim_create_buf(false, true)
	api.nvim_win_set_buf(pane, buf)
	layout.track(pane, kind, "test")
	buf = api.nvim_create_buf(false, true)
	vim.bo[buf].buftype = "nofile"
	layout.set_buf(pane, buf)

	assert(vim.wo[pane].winfixbuf, "intentional buffer switches must restore protection")
	assert(not pcall(layout.set_buf, pane, -1), "invalid buffer switches must fail")
	assert(vim.wo[pane].winfixbuf, "failed buffer switches must restore protection")

	api.nvim_set_current_win(editor)
	vim.cmd.copen()
	api.nvim_set_current_win(pane)
	local count = #api.nvim_tabpage_list_wins(0)
	vim.fn.setqflist({}, "a", { idx = 1 })
	vim.cmd.cnext()

	assert(api.nvim_get_current_win() == editor, kind .. ": cnext must use the editor")
	assert(api.nvim_get_current_buf() == second)
	assert(api.nvim_win_get_buf(pane) == buf, kind .. ": cnext replaced the pane")

	api.nvim_set_current_win(editor)
	vim.cmd.split()
	local composer = api.nvim_get_current_win()
	layout.set_buf(composer, api.nvim_create_buf(false, true))
	layout.track(composer, "prompt", "test")
	count = count + 1
	api.nvim_set_current_win(pane)
	vim.cmd.cprevious()

	assert(api.nvim_get_current_win() == editor, kind .. ": cprevious must use the editor")
	assert(api.nvim_get_current_buf() == first)
	assert(api.nvim_win_get_buf(pane) == buf, kind .. ": cprevious replaced the pane")
	assert(#api.nvim_tabpage_list_wins(0) == count, kind .. ": quickfix jump duplicated a window")

	api.nvim_win_close(composer, true)
	vim.cmd.cclose()
	api.nvim_win_close(pane, true)
end

print("Quickfix pane tests passed (open quickfix, composer focus, buffer switching, no duplicate splits).")
vim.cmd("qa!")
