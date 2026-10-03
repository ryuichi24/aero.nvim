-- Run: nvim --headless -u NONE -l tests/tasks_edit.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
-- Expected validation failures must not leave a headless native-edit test at hit-enter.
local notices = {}
vim.notify = function(message)
	table.insert(notices, message)
end
vim.o.more = false
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = require("aero.storage").canonical(root)
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	worktree_tabs = false,
	tasks = { directory = "worktree", states = { "todo", "doing", "done" }, column_width = 20 },
})
vim.o.columns = 140
local tasks, storage = require("aero.tasks"), require("aero.tasks.storage")
local ws = { root = root }
local board = assert(tasks.create_board(ws, "Editable"))
local first = assert(tasks.create_ticket(ws, board.path, "todo", "Same 日本語"))
local second = assert(tasks.create_ticket(ws, board.path, "todo", "Same 日本語"))
local ticket_text = storage.read(first.path)
-- Notes and inline comments must survive placement reconstruction.
local parsed = tasks.read_board(ws, board.path)
local lines = vim.deepcopy(parsed.lines)
lines[parsed.states[1].entries[1].line] = lines[parsed.states[1].entries[1].line] .. " <!-- follows ticket -->"
table.insert(lines, parsed.states[1].first + 1, "State note stays here.")
assert(storage.write(board.path, parsed.text, storage.text(lines, parsed.text)))
local viewmod = require("aero.tasks.view")
local view = assert(viewmod.open(ws, board.path))
assert(#view.columns == 3)
for _, column in ipairs(view.columns) do
	assert(vim.bo[column.buf].buftype == "acwrite" and vim.bo[column.buf].modifiable)
	assert(vim.fn.maparg("d", "n", false, true).buffer ~= 1)
end
local function focus(index)
	local buf = view.columns[index].buf
	local win = vim.fn.bufwinid(buf)
	assert(win ~= -1, "expected visible state")
	api.nvim_set_current_win(win)
end
local function keys(sequence)
	vim.cmd.redraw()
	api.nvim_feedkeys(api.nvim_replace_termcodes(sequence, true, false, true), "xt", false)
end
local baseline = storage.read(board.path)
focus(1)
api.nvim_win_set_cursor(0, { 1, 0 })
keys("dd")
assert(not viewmod.save(view), "missing ticket saved")
assert(storage.read(board.path) == baseline)
focus(2)
keys("p")
assert(storage.read(board.path) == baseline, "paste saved prematurely")
vim.cmd.write()
local moved = tasks.read_board(ws, board.path)
assert(moved.states[2].entries[1].path == first.path)
assert(moved.states[1].entries[1].path == second.path)
assert(moved.states[2].entries[1].raw:find("follows ticket", 1, true))
assert(moved.text:find("State note stays here.", 1, true))
assert(storage.read(first.path) == ticket_text)
assert(not viewmod.dirty(view))
local saved = storage.read(board.path)
vim.cmd.write()
vim.cmd.wall()
assert(storage.read(board.path) == saved, "no-op save rewrote board")
-- Undo in only one column is not a complete inverse movement.
keys("u")
assert(not viewmod.save(view))
assert(storage.read(board.path) == saved)
keys("<C-r>")
assert(viewmod.save(view))
-- Duplicating a row is rejected even with matching display titles.
focus(1)
keys("yyp")
assert(not viewmod.save(view))
keys("u")
assert(viewmod.save(view))
-- Keep all draft buffers intact across resizing/reentry/external changes.
focus(1)
keys("dd")
local draft = api.nvim_buf_get_lines(view.columns[1].buf, 0, -1, false)
api.nvim_exec_autocmds("WinResized", {})
viewmod.open(ws, board.path)
assert(vim.deep_equal(draft, api.nvim_buf_get_lines(view.columns[1].buf, 0, -1, false)))
focus(3)
keys("p")
assert(tasks.move_ticket(ws, board.path, second.path, "doing"))
viewmod.render(view)
assert(view.stale and viewmod.dirty(view))
assert(not viewmod.save(view), "stale baseline overwritten")
assert(tasks.read_board(ws, board.path).states[2].entries[2].path == second.path)
viewmod.render(view, true)
-- Hidden state buffers participate in validation and commit.
focus(2)
keys("dd")
local hidden = view.columns[3].buf
local line = first.metadata.id .. "  " .. first.metadata.title
api.nvim_buf_set_lines(hidden, 0, -1, false, { line })
local hiddenwin = vim.fn.bufwinid(hidden)
if hiddenwin ~= -1 then
	api.nvim_win_close(hiddenwin, true)
end
assert(viewmod.save(view))
assert(tasks.read_board(ws, board.path).states[3].entries[1].path == first.path)
-- Wiping a column is an error, never interpreted as deleting its tickets.
api.nvim_buf_delete(hidden, { force = true })
assert(not viewmod.save(view))
viewmod.render(view, true)
assert(api.nvim_buf_is_valid(view.columns[3].buf))
-- Service rejects incomplete and foreign identities without changing files.
local current = tasks.read_board(ws, board.path)
assert(not tasks.apply_layout(ws, board.path, {
	expected_text = current.text,
	states = {
		{ name = "todo", ticket_ids = {} },
		{ name = "doing", ticket_ids = {} },
		{ name = "done", ticket_ids = {} },
	},
}))
assert(storage.read(board.path) == current.text)

-- A visual multi-ticket move is one board commit, and uses full IDs, not titles.
local multi = assert(tasks.create_board(ws, "Visual"))
local a = assert(tasks.create_ticket(ws, multi.path, "todo", "Repeated"))
local b = assert(tasks.create_ticket(ws, multi.path, "todo", "Repeated"))
view = assert(viewmod.open(ws, multi.path))
focus(1)
keys("ggVjd")
focus(2)
keys("p")
vim.cmd.write()
local visual = tasks.read_board(ws, multi.path)
assert(#visual.states[1].entries == 0 and #visual.states[2].entries == 2)
assert(visual.states[2].entries[1].path == a.path and visual.states[2].entries[2].path == b.path)

-- Title edits are diagnosed, and unsaved source Markdown blocks a valid draft.
focus(2)
keys("A changed<Esc>")
assert(not viewmod.save(view))
keys("u")
focus(2)
keys("dd")
focus(3)
keys("p")
local sourcebuf = vim.fn.bufadd(multi.path)
vim.fn.bufload(sourcebuf)
api.nvim_buf_set_lines(sourcebuf, 0, 0, false, { "unsaved" })
assert(not viewmod.save(view))
assert(storage.read(multi.path) == visual.text)
vim.bo[sourcebuf].modified = false
api.nvim_buf_delete(sourcebuf, { force = true })
assert(viewmod.save(view))

-- Native movement and resize do not perform any filesystem reads.
local original_read, reads = storage.read, 0
storage.read = function(...)
	reads = reads + 1
	return original_read(...)
end
keys("hjk")
api.nvim_exec_autocmds("WinResized", {})
assert(reads == 0)
storage.read = original_read
vim.fn.delete(root, "rf")
print("Editable task tests passed (native cut/paste, batch save, undo, conflicts, hidden/wiped buffers, preservation).")
vim.cmd.qa({ bang = true })
