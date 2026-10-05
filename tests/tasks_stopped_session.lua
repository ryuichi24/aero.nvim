-- AERO_MCP_EXECUTABLE=/absolute/aero-mcp nvim --headless -u NONE -l tests/tasks_stopped_session.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local executable = assert(vim.env.AERO_MCP_EXECUTABLE)
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = require("aero.storage").canonical(root)
assert(vim.system({ "git", "init", root }):wait().code == 0)
local fixture = vim.fn.getcwd() .. "/tests/fixtures/tasks_resume.py"
local agents = {}
for _, variant in ipairs({ "supported", "unsupported", "reject", "initialize-error" }) do
	agents[variant] = { type = "acp", cmd = { "python3", fixture, variant, root .. "/" .. variant .. ".jsonl" } }
end
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	start_insert = false,
	agents = agents,
	tasks = {
		directory = "worktree",
		agent = { enabled = true, executable = executable, adapters = vim.tbl_keys(agents) },
	},
})
local tasks, agent = require("aero.tasks"), require("aero.tasks.agent")
local sessions, store, history = require("aero.session"), require("aero.store"), require("aero.history")
local bridge = require("aero.tasks.bridge")
local ws, id = { root = root }, "saved-ticket-conversation"
local board = assert(tasks.create_board(ws, "Stopped assignment"))
local first = assert(tasks.create_ticket(ws, board.path, "backlog", "First"))
local second = assert(tasks.create_ticket(ws, board.path, "backlog", "Second"))
require("aero.tasks.ui").workspace = function(callback)
	callback(ws)
end
local warnings = {}
vim.notify = function(message)
	table.insert(warnings, message)
end
local saved_usage = { tokens = { responses = 1, totalTokens = 42 }, context = { used = 7, size = 100 } }
local function saved_session(variant, name, assignment)
	local session = assert(sessions.create(root, variant, name))
	session.fresh = false
	store.set_session_field(root, session.name, "acp_session_id", id)
	if assignment then
		store.set_session_field(root, session.name, "task_assignment", assignment)
	end
	history.save(session, function()
		return {
			type = "acp",
			session_id = id,
			blocks = { { kind = "user", text = "Saved question" }, { kind = "agent", text = "Saved answer" } },
			usage = saved_usage,
		}
	end)
	history.flush(session)
	return session
end
local function log(variant)
	local path = root .. "/" .. variant .. ".jsonl"
	if vim.fn.filereadable(path) == 0 then
		return {}
	end
	return vim.tbl_map(vim.json.decode, vim.fn.readfile(path))
end
local confirmations = 0
local function work(session, ticket, on_select, cancel)
	vim.ui.select = function(items, opts, callback)
		if opts.prompt == "Assign ticket to ACP session" then
			callback("Existing session")
		elseif opts.prompt == "Existing ACP session for ticket" then
			assert(vim.tbl_contains(items, session), "stopped session missing from picker")
			assert(opts.format_item(session):find("stopped", 1, true))
			if on_select then
				on_select(callback)
			else
				callback(session)
			end
		elseif opts.prompt == "Replace assignment for " .. session.name .. "?" then
			confirmations = confirmations + 1
			if type(cancel) == "function" then
				cancel(callback)
			else
				callback(cancel and "Cancel" or "Replace assignment")
			end
		else
			error("unexpected picker " .. opts.prompt)
		end
	end
	agent.work(board.metadata.id, ticket.metadata.id)
end
local function wait_assignment(session)
	assert(
		vim.wait(5000, function()
			return not session.task_assignment_pending
		end),
		"assignment did not finish"
	)
end
local function ticket_from(transport)
	local result
	vim.system({ executable, "call", "--socket", transport.socket, "get_ticket" }, {
		text = true,
		env = { AERO_TASK_CREDENTIAL = transport.credential },
	}, function(value)
		result = value
	end)
	assert(vim.wait(5000, function()
		return result ~= nil
	end))
	if result.code == 0 then
		return vim.json.decode(result.stdout).ticket_id
	end
	assert(result.stderr:find("NOT_FOUND", 1, true), result.stderr)
end
local function draft(session)
	return table.concat(api.nvim_buf_get_lines(session.chat:get_prompt_buf(), 0, -1, false), "\n")
end
local function stop(session)
	sessions.stop(session)
	assert(vim.wait(5000, function()
		return session.chat.client.closed
	end))
end
local saved = saved_session("supported", "Previously saved")
local key, count = saved.key, #sessions.all()
work(saved, first)
wait_assignment(saved)
assert(saved.chat.state == "ready" and saved.chat.resumed and saved.chat.session_id == id)
assert(saved.key == key and #sessions.all() == count and saved.worktree == root)
assert(saved.task_binding.ticket_id == first.metadata.id and ticket_from(saved.task_transport) == first.metadata.id)
assert(store.find_session(root, saved.name).task_assignment.ticket_id == first.metadata.id)
assert(vim.deep_equal(saved.chat.usage, saved_usage))
assert(saved.chat.modes.currentModeId == "plan")
local conversation = vim.tbl_filter(function(block)
	return block.kind == "user" or block.kind == "agent"
end, saved.chat.blocks)
assert(#conversation == 2 and conversation[1].text == "Saved question" and conversation[2].text == "Saved answer")
assert(draft(saved):find(first.metadata.id, 1, true))
local requests = log("supported")
assert(#requests == 2 and requests[1].method == "initialize" and requests[2].method == "session/load")
assert(requests[2].params.sessionId == id and requests[2].params.cwd == root)

-- Resuming a stopped runtime session retains the draft and stages the new tools.
api.nvim_buf_set_lines(saved.chat:get_prompt_buf(), 0, -1, false, { "Keep my stopped-session draft." })
local old_transport = saved.task_transport
stop(saved)
work(saved, second)
wait_assignment(saved)
assert(confirmations == 1 and saved.chat.state == "ready" and saved.chat.session_id == id)
assert(draft(saved):find("Keep my stopped-session draft.", 1, true) == 1)
assert(draft(saved):find(second.metadata.id, 1, true))
assert(ticket_from(saved.task_transport) == second.metadata.id and not ticket_from(old_transport))
assert(store.find_session(root, saved.name).task_assignment.ticket_id == second.metadata.id)
assert(#log("supported") == 4, "resume made an extra load or submitted a prompt")
stop(saved)
work(saved, second)
wait_assignment(saved)
assert(saved.chat.state == "ready" and confirmations == 1 and #log("supported") == 6)
stop(saved)

-- A saved assignment with no runtime binding still requires replacement confirmation.
local previous_assignment = { workspace_root = root, board_id = board.metadata.id, ticket_id = first.metadata.id }
local rejected = saved_session("reject", "Saved previous assignment", previous_assignment)
work(rejected, second, nil, true)
assert(not rejected.chat and #log("reject") == 0 and not rejected.task_transport)
assert(vim.deep_equal(store.find_session(root, rejected.name).task_assignment, previous_assignment))
local pending_transport
local original_bind = bridge.bind
bridge.bind = function(binding)
	local transport, err = original_bind(binding)
	pending_transport = transport
	return transport, err
end
work(rejected, second)
wait_assignment(rejected)
assert(rejected.chat.state == "exited" and not rejected.task_binding and not rejected.task_transport)
assert(vim.deep_equal(store.find_session(root, rejected.name).task_assignment, previous_assignment))
assert(store.find_session(root, rejected.name).acp_session_id == id)
assert(not ticket_from(pending_transport))
assert(#log("reject") == 2 and log("reject")[2].method == "session/load")
for _, variant in ipairs({ "unsupported", "initialize-error" }) do
	local session = saved_session(variant, variant)
	work(session, first)
	wait_assignment(session)
	assert(session.chat.state == "exited" and not session.task_binding and not session.task_transport)
	assert(not store.find_session(root, session.name).task_assignment)
	assert(store.find_session(root, session.name).acp_session_id == id)
	assert(not ticket_from(pending_transport))
	assert(#log(variant) == 1 and log(variant)[1].method == "initialize", "unsupported resume fell back to session/new")
end
bridge.bind = original_bind

-- A post-resume composition failure stops the new process and restores old tools.
local compose = require("aero.compose")
local original_append = compose.append
local old_draft = draft(saved)
old_transport = saved.task_transport
compose.append = function(session)
	api.nvim_buf_set_lines(session.chat:get_prompt_buf(), 0, -1, false, { "Partial instructions" })
	return nil, "compose rejected"
end
work(saved, first)
local failed_transport = saved.task_transport
wait_assignment(saved)
compose.append = original_append
assert(saved.chat.state == "exited" and saved.task_transport == old_transport)
assert(draft(saved) == old_draft and ticket_from(old_transport) == second.metadata.id)
assert(not ticket_from(failed_transport))
assert(store.find_session(root, saved.name).task_assignment.ticket_id == second.metadata.id)
assert(vim.wait(5000, function()
	return saved.chat.client.closed
end))

-- Launch failure cannot persist the attempted replacement or leak its credential.
local config = require("aero.config").options
local cmd = config.agents.supported.cmd
config.agents.supported.cmd = { root .. "/missing-acp-executable" }
bridge.bind = function(binding)
	local transport, err = original_bind(binding)
	failed_transport = transport
	return transport, err
end
work(saved, first)
wait_assignment(saved)
bridge.bind = original_bind
config.agents.supported.cmd = cmd
assert(not saved.chat and saved.task_transport == old_transport and not ticket_from(failed_transport))
assert(store.find_session(root, saved.name).task_assignment.ticket_id == second.metadata.id)
work(saved, second)
wait_assignment(saved)
assert(saved.chat.state == "ready" and saved.chat.session_id == id and draft(saved):find(old_draft, 1, true) == 1)
stop(saved)

-- Revalidate a stopped session after selection, before starting its process.
local n = #log("supported")
local buf = vim.fn.bufadd(first.path)
vim.fn.bufload(buf)
work(saved, first, function(callback)
	api.nvim_buf_set_lines(buf, -1, -1, false, { "Unsaved draft" })
	callback(saved)
end)
assert(#log("supported") == n and not saved.task_assignment_pending)
assert(warnings[#warnings]:find("save board and ticket drafts", 1, true))
vim.bo[buf].modified = false
work(saved, first, nil, function(callback)
	store.set_session_field(root, saved.name, "task_assignment", previous_assignment)
	callback("Replace assignment")
end)
assert(#log("supported") == n and warnings[#warnings]:find("assignment changed", 1, true))
work(saved, first, function(callback)
	callback(nil)
end)
assert(#log("supported") == n and saved.chat.state == "exited")
local deleted = saved_session("supported", "Deleted before resume")
work(deleted, first, function(callback)
	sessions.delete(deleted)
	callback(deleted)
end)
assert(#log("supported") == n and not store.find_session(root, deleted.name))

for _, session in ipairs(sessions.all()) do
	sessions.delete(session)
end
bridge.stop()
vim.fn.delete(root, "rf")
print("Stopped-ticket session tests passed (saved/live resume, strict load, rollback, drafts, credentials).")
vim.cmd("qa!")
