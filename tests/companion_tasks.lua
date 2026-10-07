-- AERO_MCP_EXECUTABLE=/absolute/aero-mcp nvim --headless -u NONE -l tests/companion_tasks.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local fixture = vim.fn.getcwd() .. "/tests/fixtures/modes.py"
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	start_insert = false,
	agents = { fixture = { type = "acp", cmd = { "python3", fixture, "config" } } },
	tasks = {
		directory = "worktree",
		states = { "todo", "review" },
		agent = { enabled = true, executable = assert(vim.env.AERO_MCP_EXECUTABLE), adapters = { "fixture" } },
	},
})
local store, tasks = require("aero.store"), require("aero.tasks")
store.add_workspace(root)
local ws = store.find_workspace(root)
require("aero.git").list = function()
	return { { path = root } }
end
local board = assert(tasks.create_board(ws, "Brainstorm"))
local other = assert(tasks.create_board(ws, "Other"))
local ticket = assert(tasks.create_ticket(ws, board.path, "todo", "Assigned work"))
local s = assert(require("aero.session").create(root, "fixture", "Mobile brainstorm"))
assert(require("aero.panel").show(s))
assert(vim.wait(5000, function()
	return s.chat.state == "ready"
end))
local companion = require("aero.companion")
local snapshot = companion.dispatch("snapshot")
assert(#snapshot.boards == 2 and not snapshot.sessions[1].assignment)
local params = {
	operation_id = "mobile-board-assignment-1",
	epoch = snapshot.epoch,
	session = s.key,
	target = snapshot.sessions[1].target,
	conversation = snapshot.sessions[1].conversation,
	workspace = root,
	board_id = board.metadata.id,
	replace = false,
}
local buf = s.chat:get_prompt_buf()
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Preserve my editor draft" })
local id, blocks = s.chat.session_id, vim.deepcopy(s.chat.blocks)
local result, err = companion.dispatch(
	"session_assign_board",
	vim.tbl_extend("force", params, { operation_id = "mobile-stale-assignment", target = "stale" })
)
assert(not result and err:find("stale"))
result, err = companion.dispatch("session_assign_board", params)
assert(result, err)
assert(vim.wait(5000, function()
	return not s.chat.task_pending
end))
assert(companion.dispatch("session_assign_board", params).status == "accepted")
local transport = s.task_transport
assert(companion.dispatch("session_assign_board", params).status == "accepted" and s.task_transport == transport)
assert(s.chat.session_id == id and vim.deep_equal(s.chat.blocks, blocks))
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "Preserve my editor draft")
local assignment = companion.dispatch("snapshot").sessions[1].assignment
assert(assignment.board_id == board.metadata.id and assignment.board_title == "Brainstorm" and not assignment.ticket_id)
assert(store.find_session(root, s.name).task_assignment.board_id == board.metadata.id)
assert(require("aero.tasks.status").label(s):find("none (board-only)", 1, true))
local original_prompt, sent = s.chat.prompt, nil
s.chat.prompt = function(_, text)
	sent = text
end
assert(companion.dispatch("prompt", {
	operation_id = "mobile-brainstorm-prompt",
	session = s.key,
	conversation = params.conversation,
	text = "Create three todo tickets from our ideas.",
}).status == "accepted")
assert(sent:find(board.metadata.id, 1, true) and sent:find("Board-only assignment", 1, true))
assert(sent:find("Create three todo tickets", 1, true))
s.chat.prompt = original_prompt
result, err = companion.dispatch(
	"session_assign_board",
	vim.tbl_extend("force", params, { operation_id = "mobile-replace-refused", board_id = other.metadata.id })
)
assert(not result and err:find("confirm replacement") and s.task_transport == transport)
s.chat.busy = true
result, err = companion.dispatch(
	"session_assign_board",
	vim.tbl_extend("force", params, { operation_id = "mobile-busy-assignment" })
)
assert(not result and err:find("wait"))
s.chat.busy = false
-- A rejected provider reload restores the previous assignment and saved identity.
local request = s.chat.client.request
local fail_next = true
s.chat.client.request = function(client, method, arguments, callback)
	if method == "session/load" and fail_next then
		fail_next = false
		vim.schedule(function()
			callback("injected assignment failure")
		end)
		return
	end
	return request(client, method, arguments, callback)
end
local failed = vim.tbl_extend("force", params, {
	operation_id = "mobile-reload-failure",
	board_id = other.metadata.id,
	replace = true,
})
assert(companion.dispatch("session_assign_board", failed))
assert(vim.wait(5000, function()
	return not s.chat.task_pending
end))
result, err = companion.dispatch("session_assign_board", failed)
assert(not result and err == "injected assignment failure")
assert(s.task_transport == transport and s.task_binding.board_id == board.metadata.id)
assert(store.find_session(root, s.name).task_assignment.board_id == board.metadata.id)
s.chat.client.request = request
-- Confirmed replacement changes the same conversation's binding.
local replacement = vim.tbl_extend("force", params, {
	operation_id = "mobile-confirmed-replace",
	board_id = other.metadata.id,
	replace = true,
})
assert(companion.dispatch("session_assign_board", replacement))
assert(vim.wait(5000, function()
	return not s.chat.task_pending
end))
assert(companion.dispatch("session_assign_board", replacement).status == "accepted")
assert(s.task_binding.board_id == other.metadata.id and s.chat.session_id == id)
s.task_binding.board_id = board.metadata.id
s.task_binding.ticket_id = ticket.metadata.id
require("aero.tasks.agent").remember(s)
assignment = require("aero.tasks.status").describe(s)
assert(assignment.ticket_title == "Assigned work" and assignment.ticket_state == "todo")
s.task_binding = nil
assert(require("aero.tasks.status").describe(s).ticket_id == ticket.metadata.id)
s.chat:stop()
require("aero.tasks.bridge").stop()
vim.fn.delete(root, "rf")
print("companion tasks: ok")
vim.cmd("qa!")
