-- Run: nvim --headless -u NONE -l tests/tasks_cmdwin.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = require("aero.storage").canonical(root)
require("aero").setup({
	animation = false,
	state_file = root .. "/state.json",
	tasks = { directory = "worktree", states = { "todo", "doing", "done" }, column_width = 32 },
})
local tasks, viewmod = require("aero.tasks"), require("aero.tasks.view")
local ws = { root = root }
local board = assert(tasks.create_board(ws, "Command window"))
assert(tasks.create_ticket(ws, board.path, "todo", "Search this ticket"))
local view = assert(viewmod.open(ws, board.path))
viewmod.actions(view).open()
local ticket_window = api.nvim_get_current_win()
local errors, entered = {}, false
local schedule = vim.schedule
vim.schedule = function(callback)
	schedule(function()
		local ok, err = pcall(callback)
		if not ok then
			table.insert(errors, err)
		end
	end)
end
api.nvim_create_autocmd("CmdwinEnter", {
	once = true,
	callback = function()
		entered = true
		local command_window = api.nvim_get_current_win()
		assert(vim.fn.getcmdwintype() == "/")
		vim.o.columns = 120
		api.nvim_exec_autocmds("VimResized", {})
		api.nvim_exec_autocmds("FocusGained", {})
		vim.wait(100, function()
			return false
		end, 10)
		assert(api.nvim_get_current_win() == command_window, "resize stole command-window focus")
		assert(#errors == 0, table.concat(errors, "\n"))
		api.nvim_feedkeys(api.nvim_replace_termcodes("<C-c>", true, false, true), "n", false)
	end,
})
vim.cmd.normal({ args = { "q/" }, bang = true })
assert(entered and vim.fn.getcmdwintype() == "")
vim.wait(100, function()
	return false
end, 10)
assert(#errors == 0, table.concat(errors, "\n"))
assert(api.nvim_get_current_win() == ticket_window)
assert(api.nvim_win_get_config(ticket_window).width == 96, "deferred float resize did not resume")
local visible = 0
for _, column in ipairs(view.columns) do
	if vim.fn.bufwinid(column.buf) ~= -1 then
		visible = visible + 1
	end
end
assert(visible == 3, "deferred column reflow did not resume")
vim.schedule = schedule
vim.fn.delete(root, "rf")
print("Command-window tests passed (no E11, focus preserved, deferred float/column resize).")
vim.cmd.qa({ bang = true })
