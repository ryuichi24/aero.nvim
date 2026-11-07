-- Run: nvim --headless -u NONE -i NONE -l tests/terminal_tabs.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.columns = 160
vim.o.lines = 60
local api = vim.api
local terminal = require("aero.terminal")
local path = vim.fn.getcwd()
local code = api.nvim_get_current_win()
require("aero.config").options.terminal.cmd = { "/bin/sh" }
require("aero.config").options.terminal.prompt_for_name = false
package.loaded["aero.navigation"] = {
	enter_worktree = function(target)
		vim.t.aero_worktree = target
		return true
	end,
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

local function dimensions()
	local result = {}

	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if terminal.is_term_win(win) then
			result[api.nvim_win_get_buf(win)] = { api.nvim_win_get_width(win), api.nvim_win_get_height(win) }
		end
	end

	return result
end

local ok, err = xpcall(function()
	terminal.open(path, code)
	local first = api.nvim_get_current_buf()

	assert(vim.wo.winbar:match("%l+%-%l+%-%d+"), "new terminal receives a readable generated name")

	terminal.rename("Dev server 100%")

	assert(vim.wo.winbar:find("[1: Dev server 100%%]", 1, true), "name escapes winbar formatting")

	terminal.action("vsplit")
	terminal.action("split")
	local original = panes()

	assert(#original == 3, "three independent panes")

	api.nvim_win_set_width(api.nvim_get_current_win(), 57)
	api.nvim_win_set_height(api.nvim_get_current_win(), 5)
	local original_sizes = dimensions()

	for _ = 1, 3 do
		terminal.hide()
		terminal.open(path, code)

		assert(vim.deep_equal(dimensions(), original_sizes), "toggle preserves each pane's width and height")
	end

	local jobs = {}

	for _, buf in ipairs(original) do
		local job = vim.b[buf].terminal_job_id

		assert(job and not jobs[job], "each pane has an independent shell")

		jobs[job] = true
	end

	terminal.action("new")
	local second = api.nvim_get_current_buf()

	assert(#panes() == 1 and second ~= first, "new tab has its own shell")

	terminal.rename("Build logs")
	local picker = require("aero.picker")
	local open, close = picker.open, picker.close
	local options
	picker.open = function(opts)
		options = opts
	end
	picker.close = function() end
	terminal.search()
	local entries = options.items()

	assert(#entries == 2, "search includes hidden and visible terminal tabs")
	assert(options.label(entries[1]):find("Build logs", 1, true), "search labels include names")

	options.select(entries[2])
	picker.open, picker.close = open, close

	assert(vim.deep_equal(panes(), original), "search selection jumps to hidden terminal tab")

	terminal.action("next")

	terminal.action("prev")

	assert(vim.deep_equal(panes(), original), "switch restores all original panes")
	assert(vim.deep_equal(dimensions(), original_sizes), "tab switching preserves pane dimensions")
	assert(vim.wo.winbar:find("[1: Dev server 100%%]", 1, true), "name survives tab switching")

	local input = vim.ui.input
	vim.ui.input = function(opts, callback)
		assert(opts.default == "Dev server 100%", "rename prompt contains current name")

		callback(nil)
	end
	terminal.rename()

	assert(vim.wo.winbar:find("Dev server", 1, true), "cancel preserves name")

	vim.ui.input = function(_, callback)
		callback(" ")
	end
	terminal.rename()
	vim.ui.input = input

	assert(not vim.wo.winbar:find("Dev server", 1, true), "empty name restores numbered label")

	terminal.hide()

	assert(#panes() == 0, "hide closes every terminal window")

	terminal.open(path, code)

	assert(vim.deep_equal(panes(), original), "reopen preserves shell buffers")

	terminal.action("next")

	assert(api.nvim_get_current_buf() == second, "next restores second tab")

	terminal.action("close")

	assert(not api.nvim_buf_is_valid(second), "close stops tab shell")
	assert(vim.deep_equal(panes(), original), "close selects remaining tab")

	local input = vim.ui.input
	require("aero.config").options.terminal.prompt_for_name = true
	vim.ui.input = function(_, callback)
		callback(nil)
	end
	terminal.action("new")

	assert(vim.deep_equal(panes(), original), "cancel creation preserves current panes")

	vim.ui.input = function(_, callback)
		callback("Named on creation")
	end
	terminal.action("new")
	vim.ui.input = input

	assert(vim.wo.winbar:find("Named on creation", 1, true), "new tab uses prompted name")

	terminal.action("close")

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
