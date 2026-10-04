-- nvim --headless -u NONE -l tests/tasks_agent_service.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	tasks = { directory = "worktree", states = { "todo", "review" } },
})
local tasks, storage = require("aero.tasks"), require("aero.tasks.storage")
local operations = require("aero.tasks.operations")
local ws = { root = root }
local board = assert(tasks.create_board(ws, "Agent board"))
local ticket = assert(tasks.create_ticket(ws, board.path, "todo", "Assigned"))
local ticket_text = assert(storage.read(ticket.path))
assert(
	storage.write(
		ticket.path,
		ticket_text,
		ticket_text:gsub("\n%-%-%-\n", "\ncustom_field: {keep: true} # preserve comment\n---\n", 1)
	)
)
assert(tasks.create_ticket(ws, board.path, "todo", "Other"))
local binding =
	{ workspace = ws, board_id = board.metadata.id, ticket_id = ticket.metadata.id, session_key = "fixture" }
local read = assert(operations.get_ticket(binding))
assert(read.committed and read.state == "todo")
local before = assert(storage.read(board.path))
local request = {
	operation_id = "noop",
	expected_board_revision = read.board_revision,
	expected_state = "todo",
	target_state = "todo",
}
assert(operations.move_ticket(binding, request))
assert(storage.read(board.path) == before, "same-state move changed source or ordering")
request.operation_id, request.target_state = "move", "review"
local moved = assert(operations.move_ticket(binding, request))
assert(moved.state == "review")
assert(moved.metadata.state == "review" and moved.ticket_revision ~= read.ticket_revision)
assert(vim.deep_equal(moved, assert(operations.move_ticket(binding, request))), "replay differs")
request.target_state = "todo"
local result, err = operations.move_ticket(binding, request)
assert(not result and err.code == "INVALID_ARGUMENT")
request.operation_id = "stale"
result, err = operations.move_ticket(binding, request)
assert(not result and err.code == "CONFLICT" and err.actual.state == "review")
local buf = vim.fn.bufadd(ticket.path)
vim.fn.bufload(buf)
vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "Unsaved human draft" })
local blocked, blocked_err = operations.move_ticket(binding, {
	operation_id = "dirty-ticket-move",
	expected_board_revision = moved.board_revision,
	target_state = "todo",
})
assert(not blocked and blocked_err.code == "UNSAVED_DOCUMENT")
local body_request =
	{ operation_id = "dirty", expected_ticket_revision = moved.ticket_revision, body = "\nImplementation complete.\n" }
result, err = operations.update_ticket_body(binding, body_request)
assert(not result and err.code == "UNSAVED_DOCUMENT")
assert(not operations.get_ticket(binding).body:find("Unsaved human draft", 1, true), "read exposed an unsaved buffer")
vim.bo[buf].modified = false
body_request.operation_id = "body"
local updated = assert(operations.update_ticket_body(binding, body_request))
assert(updated.body:find("Implementation complete.", 1, true))
assert(updated.metadata.id == ticket.metadata.id)
assert(storage.read(ticket.path):find("custom_field: {keep: true} # preserve comment", 1, true))
local view = require("aero.tasks.view").open(ws, board.path)
vim.api.nvim_buf_set_lines(view.columns[1].buf, -1, -1, false, { "Unsaved row" })
local status = require("aero.tasks.view").status(board.path)
assert(status.dirty)
result, err = operations.move_ticket(
	binding,
	{ operation_id = "board-dirty", expected_board_revision = updated.board_revision, target_state = "todo" }
)
assert(not result and err.code == "UNSAVED_BOARD")
-- Body writes are independent of placement drafts.
assert(operations.update_ticket_body(binding, {
	operation_id = "body-with-board-draft",
	expected_ticket_revision = updated.ticket_revision,
	body = "\nVerified.\n",
}))
assert(vim.api.nvim_buf_get_lines(view.columns[1].buf, -2, -1, false)[1] == "Unsaved row")
local current = assert(operations.get_ticket(binding))
local metadata = assert(operations.update_ticket_metadata(binding, {
	operation_id = "metadata-with-board-draft",
	expected_ticket_revision = current.ticket_revision,
	changes = { priority = "high" },
}))
assert(metadata.metadata.priority == "high")
assert(storage.read(ticket.path):find("custom_field: {keep: true} # preserve comment", 1, true))
local board_tab = vim.api.nvim_get_current_tabpage()
assert(require("aero.tabs").find(root) ~= board_tab, "board tab was claimed as a code tab")
assert(not vim.t[board_tab].aero_worktree)
-- Duplicate IDs must reject all matches, including the formerly valid first one.
local other = assert(tasks.create_board(ws, "Duplicate"))
local text = assert(storage.read(other.path))
assert(storage.write(other.path, text, text:gsub(vim.pesc(other.metadata.id), board.metadata.id)))
result, err = tasks.resolve_board(ws, board.metadata.id)
assert(not result and err.code == "AMBIGUOUS_ID")
vim.fn.delete(root, "rf")
print("Agent service tests passed (revisions, replay, drafts, identity, navigation).")
vim.cmd("qa!")
