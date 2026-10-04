-- Run: nvim --headless -u NONE -l tests/tasks_new_rows.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local notices = {}
vim.notify = function(message)
	table.insert(notices, message)
end
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = require("aero.storage").canonical(root)
require("aero").setup({
	animation = false,
	state_file = root .. "/state.json",
	tasks = { directory = "worktree", states = { "todo", "done", "custom" }, column_width = 32 },
})
local tasks, storage, viewmod = require("aero.tasks"), require("aero.tasks.storage"), require("aero.tasks.view")
local ws = { root = root }
local board = assert(tasks.create_board(ws, "Type to create"))
local old = assert(tasks.create_ticket(ws, board.path, "todo", "Existing"))
local view = assert(viewmod.open(ws, board.path))
local function normal(buf, keys)
	api.nvim_buf_call(buf, function()
		vim.cmd.normal({ args = { api.nvim_replace_termcodes(keys, true, false, true) }, bang = true })
	end)
end
local function files()
	return #storage.list(vim.fs.joinpath(vim.fs.dirname(board.path), "tickets"), "file")
end
local original = storage.read(board.path)
normal(view.columns[1].buf, "oFix [startup] 日本語<Esc>")
normal(view.columns[2].buf, "iReview  whitespace<Esc>")
normal(view.columns[3].buf, "iExisting<Esc>") -- repeated titles are separate tickets
assert(api.nvim_buf_call(view.columns[2].buf, function()
	return vim.fn.synconcealed(1, 1)[1]
end) == 0, "plain new title was mistaken for a concealed ID")
-- Move an existing ticket in the same draft as new-ticket creation.
api.nvim_set_current_win(vim.fn.bufwinid(view.columns[1].buf))
vim.cmd.normal({ args = { "ggdd" }, bang = true })
api.nvim_set_current_win(vim.fn.bufwinid(view.columns[2].buf))
vim.cmd.normal({ args = { "p" }, bang = true })
assert(storage.read(board.path) == original and files() == 1)
vim.cmd.write()
local saved = tasks.read_board(ws, board.path)
assert(saved.count == 4 and #saved.orphans == 0 and files() == 4)
assert(saved.states[1].entries[1].ticket.metadata.title == "Fix [startup] 日本語")
assert(saved.states[2].entries[1].ticket.metadata.title == "Review  whitespace")
assert(saved.states[2].entries[2].path == old.path)
assert(saved.states[3].entries[1].ticket.metadata.title == "Existing")
assert(saved.states[3].entries[1].ticket.metadata.id ~= old.metadata.id)
assert(storage.read(saved.states[1].entries[1].path):find("## Acceptance criteria", 1, true))
assert(not viewmod.dirty(view))
for _, column in ipairs(view.columns) do
	for _, line in ipairs(api.nvim_buf_get_lines(column.buf, 0, -1, false)) do
		assert(line:match("^task%-%x+  "), "saved new row did not acquire a stable concealed ID")
	end
end
local text = saved.text
vim.cmd.write()
assert(files() == 4 and storage.read(board.path) == text, "repeated save duplicated new tickets")
-- A failed final board write cleans up unchanged newly created files, retaining draft rows.
normal(view.columns[1].buf, "oRetry me<Esc>")
normal(view.columns[3].buf, "oRetry me too<Esc>")
local write = storage.write
storage.write = function(path, ...)
	if path == board.path then
		return nil, "injected board-write failure"
	end
	return write(path, ...)
end
assert(not viewmod.save(view))
storage.write = write
assert(files() == 4 and storage.read(board.path) == text)
assert(viewmod.dirty(view) and api.nvim_buf_get_lines(view.columns[1].buf, 1, 2, false)[1] == "Retry me")
assert(viewmod.save(view))
assert(files() == 6 and tasks.read_board(ws, board.path).count == 6)
-- Forged IDs and missing baseline tickets cannot become accidental creations.
normal(view.columns[3].buf, "oDo not partially create me<Esc>")
normal(view.columns[1].buf, "otask-00000000000000000000  Forged<Esc>")
assert(not viewmod.save(view) and files() == 6)
viewmod.render(view, true)
local source = storage.read(board.path)
normal(view.columns[1].buf, "oNew before conflict<Esc>")
assert(tasks.rename_board(ws, board.path, "Changed externally"))
assert(not viewmod.save(view) and files() == 6, "conflict created an unlinked ticket")
assert(storage.read(board.path) ~= source)
vim.fn.delete(root, "rf")
print(
	"Title-row ticket tests passed (native typing, hidden/custom states, mixed moves, stable IDs, rollback, conflicts)."
)
vim.cmd.qa({ bang = true })
