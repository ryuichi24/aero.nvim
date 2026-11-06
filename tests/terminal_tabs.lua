-- Run: nvim --headless -u NONE -i NONE -l tests/terminal_tabs.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.columns = 160
vim.o.lines = 60
local api = vim.api
local terminal = require("aero.terminal")
local path = vim.fn.getcwd()
local code = api.nvim_get_current_win()
require("aero.config").options.terminal.cmd = { "/bin/sh" }
package.loaded["aero.navigation"] = {
	code_window = function()
		return code
	end,
}

local function panes()
	local result = {}

	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if terminal.is_term_win(win) then
			result[#result + 1] = api.nvim_win_get_buf(win)
		end
	end

	table.sort(result)
	return result
end

local ok, err = xpcall(function()
	terminal.open(path, code)
	local first = api.nvim_get_current_buf()
	terminal.action("vsplit")
	terminal.action("split")
	local original = panes()

	assert(#original == 3, "three independent panes")

	local jobs = {}

	for _, buf in ipairs(original) do
		local job = vim.b[buf].terminal_job_id

		assert(job and not jobs[job], "each pane has an independent shell")

		jobs[job] = true
	end

	terminal.action("new")
	local second = api.nvim_get_current_buf()

	assert(#panes() == 1 and second ~= first, "new tab has its own shell")

	terminal.action("prev")

	assert(vim.deep_equal(panes(), original), "switch restores all original panes")

	terminal.hide()

	assert(#panes() == 0, "hide closes every terminal window")

	terminal.open(path, code)

	assert(vim.deep_equal(panes(), original), "reopen preserves shell buffers")

	terminal.action("next")

	assert(api.nvim_get_current_buf() == second, "next restores second tab")

	terminal.action("close")

	assert(not api.nvim_buf_is_valid(second), "close stops tab shell")
	assert(vim.deep_equal(panes(), original), "close selects remaining tab")

	terminal.delete(path)

	for _, buf in ipairs(original) do
		assert(not api.nvim_buf_is_valid(buf), "delete disposes every shell")
	end
end, debug.traceback)

if not ok then
	io.stderr:write(err .. "\n")
	vim.cmd("cquit 1")
end

print("terminal tabs: passed")
vim.cmd("qa!")
