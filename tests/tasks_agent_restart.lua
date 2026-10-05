-- AERO_MCP_EXECUTABLE=/absolute/aero-mcp nvim --headless -u NONE -l tests/tasks_agent_restart.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local executable = assert(vim.env.AERO_MCP_EXECUTABLE)
local phase = vim.env.AERO_RESTART_PHASE
if not phase then
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	assert(vim.system({ "git", "init", root }):wait().code == 0)
	for _, step in ipairs({ "create", "resume", "legacy", "missing" }) do
		local result = vim.system(
			{ vim.v.progpath, "--headless", "-u", "NONE", "-l", "tests/tasks_agent_restart.lua" },
			{
				text = true,
				env = { AERO_RESTART_PHASE = step, AERO_RESTART_ROOT = root },
			}
		)
			:wait(30000)
		assert(result.code == 0, step .. ": " .. result.stderr .. result.stdout)
	end
	vim.fn.delete(root, "rf")
	print("Task restart tests passed (separate Neovim processes, MCP writes, legacy migration, missing ticket).")
	vim.cmd("qa!")
	return
end
local root = require("aero.storage").canonical(assert(vim.env.AERO_RESTART_ROOT))
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	start_insert = false,
	agents = {
		fixture = { type = "acp", cmd = { "python3", vim.fn.getcwd() .. "/tests/fixtures/tasks_acp.py" } },
		board_fixture = { type = "acp", cmd = { "python3", vim.fn.getcwd() .. "/tests/fixtures/modes.py", "config" } },
	},
	tasks = {
		directory = "worktree",
		states = { "todo", "in progress", "review" },
		agent = { enabled = true, executable = executable, adapters = { "fixture", "board_fixture" } },
	},
})
local sessions, store, tasks = require("aero.session"), require("aero.store"), require("aero.tasks")
local s, board, ticket
if phase == "create" then
	board = assert(tasks.create_board({ root = root }, "Restart"))
	ticket = assert(tasks.create_ticket({ root = root }, board.path, "todo", "Assigned"))
	require("aero.tasks.view").open({ root = root }, board.path)
	vim.ui.select = function(items, _, callback)
		callback(vim.tbl_contains(items, "fixture") and "fixture" or items[1])
	end
	vim.ui.input = function(_, callback)
		callback("Restart task")
	end
	require("aero.tasks.agent").work(board.metadata.id, ticket.metadata.id)
	s = assert(sessions.list(root)[1])
else
	store.load()
	s = assert(sessions.list(root)[1])
	assert(not s.task_binding and not s.task_transport, "runtime connection survived process exit")
	local assignment = assert(store.find_session(root, s.name).task_assignment)
	board = assert(tasks.resolve_board({ root = root }, assignment.board_id))
	ticket = assert(tasks.resolve_ticket(board, assignment.ticket_id))
	if phase == "legacy" then
		store.set_session_field(root, s.name, "task_assignment", nil)
	elseif phase == "missing" then
		assert(tasks.remove_ticket({ root = root }, board.path, ticket.path, true))
		local message
		vim.notify = function(text)
			message = text
		end
		assert(not sessions.start(s, vim.api.nvim_get_current_win(), true))
		assert(message:find("cannot reconnect task tools", 1, true))
		assert(store.find_session(root, s.name).task_assignment.ticket_id == assignment.ticket_id)
		vim.cmd("qa!")
		return
	end
	assert(sessions.start(s, vim.api.nvim_get_current_win(), true))
end
assert(vim.wait(10000, function()
	return s.chat.state == "ready" or s.chat.state == "exited"
end))
assert(s.chat.state == "ready", table.concat(s.chat.client.stderr, ""))
if phase == "create" then
	s.chat:send_prompt_buf()
else
	assert(s.chat.resumed, "provider conversation did not resume")
	assert(s.task_binding.ticket_id == ticket.metadata.id)
	assert(vim.tbl_contains(s.task_documents, ticket.path), "resumed ticket lost ACP write protection")
	s.chat:prompt("Record the resolved decision on the ticket.")
end
assert(vim.wait(15000, function()
	return not s.chat.busy
end))
assert(s.chat.state == "ready", table.concat(s.chat.client.stderr, ""))
local read = assert(require("aero.tasks.operations").get_ticket(s.task_binding))
assert(read.body:find("Implemented and verified", 1, true), "MCP ticket update failed after restart")
local assignment = assert(store.find_session(root, s.name).task_assignment)
assert(assignment.workspace_root == root and assignment.ticket_id == ticket.metadata.id)
local encoded = vim.json.encode(store.data)
assert(not encoded:find(s.task_transport.credential, 1, true), "credential was persisted")
assert(not encoded:find(s.task_transport.socket, 1, true), "socket was persisted")
sessions.stop(s)
-- Board-only identities reconnect without inventing a ticket assignment.
local planner
local agent = require("aero.tasks.agent")
if phase == "create" then
	planner = assert(sessions.create(root, "board_fixture", "Board planner"))
	assert(agent.attach(planner, { workspace = { root = root }, board_id = board.metadata.id }, executable))
	agent.remember(planner)
else
	for _, candidate in ipairs(sessions.list(root)) do
		if candidate.name == "Board planner" then
			planner = candidate
		end
	end
	assert(planner and not planner.task_binding)
end
assert(sessions.start(planner, vim.api.nvim_get_current_win(), phase ~= "create"))
assert(vim.wait(10000, function()
	return planner.chat.state == "ready" or planner.chat.state == "exited"
end))
assert(planner.chat.state == "ready", table.concat(planner.chat.client.stderr, ""))
assert(planner.task_binding.board_id == board.metadata.id and not planner.task_binding.ticket_id)
assert(#planner.task_documents == 1 and planner.task_documents[1] == board.path)
assert(require("aero.tasks.operations").get_board(planner.task_binding))
assert(store.find_session(root, planner.name).task_assignment.ticket_id == nil)
if phase ~= "create" then
	assert(planner.chat.resumed)
end
sessions.stop(planner)
vim.cmd("qa!")
