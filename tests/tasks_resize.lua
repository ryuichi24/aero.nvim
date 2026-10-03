-- Run: nvim --headless -u NONE -l tests/tasks_resize.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = require("aero.storage").canonical(root)
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	tasks = { directory = "worktree", states = { "todo", "doing", "review", "done" }, column_width = 32 },
})
local tasks, storage = require("aero.tasks"), require("aero.tasks.storage")
local viewmod = require("aero.tasks.view")
local ws = { root = root }
local board = assert(tasks.create_board(ws, "Resizing"))
local ticket = assert(tasks.create_ticket(ws, board.path, "todo", "Keep my draft"))
local origin = api.nvim_get_current_tabpage()
local origin_win, origin_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local view = assert(viewmod.open(ws, board.path))
local function windows()
	local result = {}
	for _, win in ipairs(api.nvim_tabpage_list_wins(view.tab)) do
		for _, column in ipairs(view.columns) do
			if api.nvim_win_get_buf(win) == column.buf then
				table.insert(result, win)
				break
			end
		end
	end
	return result
end
local function resize(width, count)
	vim.o.columns = width
	api.nvim_exec_autocmds("VimResized", {})
	assert(
		vim.wait(2000, function()
			return #windows() == count
		end, 10),
		"wrong visible state count after resize"
	)
	vim.wait(100, function()
		return false
	end, 10)
end
resize(80, 2)
local todo = view.columns[1].buf
local lines = api.nvim_buf_get_lines(todo, 0, -1, false)
api.nvim_buf_set_lines(todo, 0, -1, false, { "" })
api.nvim_buf_set_lines(view.columns[4].buf, 0, -1, false, lines)
-- Add/remove state windows with no filesystem reads and without saving/replacing drafts.
local original_read, reads = storage.read, 0
storage.read = function(...)
	reads = reads + 1
	return original_read(...)
end
resize(160, 4)
assert(api.nvim_get_current_buf() == todo, "resize changed focused state")
local wide = windows()
local min, max = 1000, 0
for _, win in ipairs(wide) do
	min = math.min(min, api.nvim_win_get_width(win))
	max = math.max(max, api.nvim_win_get_width(win))
end
assert(max - min <= 2, "columns not balanced")
resize(70, 2)
assert(vim.deep_equal(lines, api.nvim_buf_get_lines(view.columns[4].buf, 0, -1, false)), "hidden draft lost")
assert(viewmod.dirty(view) and reads == 0, "resize reloaded/saved Markdown")
-- An inactive board catches the screen resize when its tab is entered again.
api.nvim_set_current_tabpage(origin)
vim.o.columns = 160
api.nvim_exec_autocmds("VimResized", {})
vim.wait(100, function()
	return false
end, 10)
assert(api.nvim_get_current_tabpage() == origin and api.nvim_get_current_win() == origin_win)
assert(api.nvim_win_get_buf(origin_win) == origin_buf)
api.nvim_set_current_tabpage(view.tab)
assert(vim.wait(2000, function()
	return #windows() == 4
end, 10))
assert(reads == 0)
storage.read = original_read
assert(viewmod.save(view))
assert(tasks.read_board(ws, board.path).states[4].entries[1].path == ticket.path)
vim.fn.delete(root, "rf")
print("Board resize tests passed (monitor widths, balanced columns, inactive tabs, drafts, no filesystem reads).")
vim.cmd.qa({ bang = true })
