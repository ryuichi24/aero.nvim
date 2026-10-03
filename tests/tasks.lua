-- Run: nvim --headless -u NONE -l tests/tasks.lua (requires Mike Farah's yq v4)
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = require("aero.storage").canonical(root)
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	tasks = { directory = "worktree", states = { "todo", "done" } },
})
local tasks = require("aero.tasks")
local storage = require("aero.tasks.storage")
local ws = { root = root }
local function must(result, err)
	assert(result, err)
	return result
end
local board = must(tasks.create_board(ws, "Product [core]", { tags = { "release" }, description = "Summary" }))
assert(#board.states == 2 and board.states[2].name == "done", "default list did not replace")
local other = must(tasks.create_board(ws, "Maintenance"))
local ticket = must(
	tasks.create_ticket(
		ws,
		board.path,
		"todo",
		"Fix [a] \\ b",
		{ priority = "high", estimate = 3, due_date = "2026-10-15", assignees = { "ryu" } },
		{ "Keep this prose.", "", "- [ ] Acceptance", "" }
	)
)
local second = must(tasks.create_ticket(ws, board.path, "todo", "Second"))
local source = assert(storage.read(board.path))
must(
	storage.write(
		board.path,
		source,
		source:gsub("## todo\n", "## todo\n\n<!-- keep state comment -->\nState prose stays.\n", 1)
	)
)
source = assert(storage.read(ticket.path))
must(
	storage.write(
		ticket.path,
		source,
		source:gsub("\n%-%-%-\n", "\ncustom_field: {keep: true} # metadata note\n---\n", 1)
	)
)
board = must(tasks.read_board(ws, board.path))
assert(board.count == 2 and #board.diagnostics == 0, table.concat(board.diagnostics, "; "))
assert(board.states[1].entries[1].ticket.metadata.title == ticket.metadata.title)
must(tasks.move_ticket(ws, board.path, ticket.path, "done"))
must(tasks.move_ticket(ws, board.path, ticket.path, "todo", 1))
board = must(tasks.read_board(ws, board.path))
assert(board.states[1].entries[1].path == ticket.path)
must(tasks.rename_ticket(ws, board.path, ticket.path, "Renamed"))
assert(storage.read(ticket.path):find("Keep this prose.", 1, true))
assert(storage.read(ticket.path):find("custom_field: {keep: true} # metadata note", 1, true))
board = must(tasks.read_board(ws, board.path))
assert(board.states[1].entries[1].label == "Renamed")
must(tasks.rename_board(ws, board.path, "New board title"))
assert(storage.read(board.path):find("# New board title", 1, true))
must(tasks.add_state(ws, board.path, "review", 2))
must(tasks.rename_state(ws, board.path, "review", "test"))
must(tasks.reorder_state(ws, board.path, "test", 1))
assert(tasks.read_board(ws, board.path).states[1].name == "test")
assert(not tasks.remove_state(ws, board.path, "todo"), "populated state removed without destination")
must(tasks.remove_state(ws, board.path, "todo", "test"))
assert(tasks.read_board(ws, board.path).states[1].entries[1].path == ticket.path)
assert(storage.read(board.path):find("<!-- keep state comment -->", 1, true))
assert(storage.read(board.path):find("State prose stays.", 1, true))
assert(not tasks.move_ticket(ws, other.path, ticket.path, "todo"), "cross-board movement accepted")
must(tasks.remove_ticket(ws, board.path, second.path))
board = must(tasks.read_board(ws, board.path))
assert(#board.orphans == 1 and vim.uv.fs_stat(second.path))
must(tasks.move_ticket(ws, board.path, second.path, "done"))
assert(#tasks.read_board(ws, board.path).orphans == 0)
local buf = vim.fn.bufadd(ticket.path)
vim.fn.bufload(buf)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved" })
assert(not tasks.rename_ticket(ws, board.path, ticket.path, "Overwrite"), "unsaved buffer overwritten")
vim.bo[buf].modified = false
must(tasks.update_metadata(ws, board.path, ticket.path, { tags = { "a", "b" }, estimate = 5 }))
assert(tasks.read_ticket(board.path, ticket.path).metadata.estimate == 5)
assert(
	table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("estimate: 5", 1, true),
	"unmodified ticket buffer not refreshed"
)
local board_buf = vim.fn.bufadd(board.path)
vim.fn.bufload(board_buf)
vim.api.nvim_buf_set_lines(board_buf, 0, -1, false, { "unsaved board" })
source = storage.read(board.path)
assert(not tasks.move_ticket(ws, board.path, ticket.path, "done"), "unsaved board overwritten")
assert(storage.read(board.path) == source)
vim.bo[board_buf].modified = false
must(tasks.archive_board(ws, board.path))
assert(tasks.read_board(ws, board.path).metadata.archived)
must(tasks.remove_ticket(ws, board.path, second.path, true))
assert(not vim.uv.fs_stat(second.path))
must(tasks.delete_board(ws, board.path))
assert(vim.uv.fs_stat(other.path), "deleting board affected other board")
vim.fn.delete(root, "rf")
print("Task service tests passed (operations, ownership, recovery, metadata, buffers).")
vim.cmd.qa({ bang = true })
