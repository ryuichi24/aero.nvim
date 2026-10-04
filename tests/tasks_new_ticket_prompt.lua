-- nvim --headless -u NONE -l tests/tasks_new_ticket_prompt.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
local fixture = vim.fn.getcwd() .. "/tests/fixtures/modes.py"
vim.fn.mkdir(root, "p")
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	start_insert = false,
	agents = { fixture = { type = "acp", cmd = { "python3", fixture, "config" } } },
})
local sessions = require("aero.session")
local s = assert(sessions.create(vim.fn.getcwd(), "fixture", "New ticket prompt"))
assert(require("aero.panel").show(s))
assert(vim.wait(5000, function()
	return s.chat and s.chat.state == "ready"
end))
local chat = s.chat
local buf = chat:get_prompt_buf()
local request = "/new-ticket Cover the edge case.\nInclude regression acceptance criteria."
api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(request, "\n"))
local notify, warning = vim.notify, nil
vim.notify = function(message)
	warning = message
end
chat:send_prompt_buf()
vim.notify = notify
assert(warning:find("tasks.agent.enabled", 1, true))
assert(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") == request, "unbound draft was lost")
s.task_binding = { board_id = "board", ticket_id = "assigned" }
s.mcp_servers = { { name = "aero-tasks" } }
local sent = {}
local original_request = chat.client.request
chat.client.request = function(_, method, params, callback)
	assert(method == "session/prompt")
	table.insert(sent, params.prompt[1].text)
	callback(nil, { stopReason = "end_turn" })
end
chat:send_prompt_buf()
assert(#sent == 1 and sent[1]:find("First call aero_get_board", 1, true))
assert(sent[1]:find("aero_create_ticket", 1, true))
assert(sent[1]:find("Cover the edge case.\nInclude regression acceptance criteria.", 1, true))
assert(not sent[1]:find("/new-ticket", 1, true), "local command reached provider")
assert(chat.blocks[#chat.blocks].text == sent[1])
chat.busy = true
chat:prompt("/new-ticket Another follow-up")
assert(#sent == 1 and #chat.queue == 1)
chat.busy = false
chat:flush_queue()
assert(#sent == 2 and sent[2]:find("Another follow-up", 1, true))
chat:prompt("/new-ticket")
assert(sent[3]:find("follow-up discussed in this conversation", 1, true))
chat:prompt("/new-ticket-other")
assert(sent[4] == "/new-ticket-other")
api.nvim_set_current_buf(buf)
vim.b.aero_chat_key = s.key
chat.commands = { { name = "new-ticket", description = "Provider duplicate" } }
local completion = require("aero.acp").omnifunc(0, "/new")
assert(#completion == 1 and completion[1].word == "/new-ticket")
-- Attach the MCP server to a regular conversation on an empty board.
local executable = assert(vim.env.AERO_MCP_EXECUTABLE, "build aero-mcp and set AERO_MCP_EXECUTABLE")
local config = require("aero.config").options
config.tasks.directory = "worktree"
config.tasks.agent.enabled = true
config.tasks.agent.executable = executable
config.tasks.agent.adapters = { "fixture" }
local tasks = require("aero.tasks")
local board = assert(tasks.create_board({ root = root }, "Empty board"))
s.task_binding, s.mcp_servers = nil, nil
local worktree = s.worktree
s.worktree = root
local loaded = false
chat.client.request = function(_, method, params, callback)
	if method == "session/load" then
		assert(params.sessionId == chat.session_id and params.mcpServers[1].name == "aero-tasks")
		loaded = true
		callback(nil, {})
	else
		assert(method == "session/prompt" and loaded)
		table.insert(sent, params.prompt[1].text)
		callback(nil, { stopReason = "end_turn" })
	end
end
api.nvim_buf_set_lines(buf, 0, -1, false, { "/new-ticket Plan the initial implementation" })
chat:send_prompt_buf()
assert(loaded and s.task_binding.board_id == board.metadata.id and not s.task_binding.ticket_id)
assert(sent[5]:find("Plan the initial implementation", 1, true))
local operations = require("aero.tasks.operations")
local read = assert(operations.get_board(s.task_binding))
local created = assert(operations.create_ticket(s.task_binding, {
	operation_id = "first",
	expected_board_revision = read.board_revision,
	title = "Initial implementation",
	target_state = read.states[1].name,
	body = "## Description\n\nInitial requirements.",
}))
assert(created.title == "Initial implementation" and tasks.read_board({ root = root }, board.path).count == 1)
local ticket, err = operations.get_ticket(s.task_binding)
assert(not ticket and err.code == "INVALID_ARGUMENT")
s.worktree = worktree
chat.client.request = original_request
sessions.delete(s)
-- A fresh board-only session also works without an assigned ticket.
assert(vim.system({ "git", "init", root }):wait().code == 0)
local empty = assert(tasks.create_board({ root = root }, "Fresh empty board"))
require("aero.tasks.view").open({ root = root }, empty.path)
vim.ui.select = function(items, _, callback)
	callback(items[1])
end
vim.ui.input = function(_, callback)
	callback("Board planning")
end
require("aero.tasks.agent").work(empty.metadata.id, nil, true)
local planning = assert(sessions.list(require("aero.storage").canonical(root))[1])
assert(vim.wait(5000, function()
	return planning.chat and planning.chat.state == "ready"
end))
assert(planning.task_binding.board_id == empty.metadata.id and not planning.task_binding.ticket_id)
local draft = table.concat(api.nvim_buf_get_lines(planning.chat:get_prompt_buf(), 0, -1, false), "\n")
assert(draft:find("Board-only session", 1, true))
assert(tasks.read_board({ root = root }, empty.path).count == 0)
sessions.delete(planning)
require("aero.tasks.bridge").stop()
vim.fn.delete(root, "rf")
print("New-ticket prompt tests passed (expansion, drafts, queue, completion).")
vim.cmd("qa!")
