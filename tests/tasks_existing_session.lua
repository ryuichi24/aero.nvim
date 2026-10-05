-- AERO_MCP_EXECUTABLE=/absolute/aero-mcp nvim --headless -u NONE -l tests/tasks_existing_session.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local executable = assert(vim.env.AERO_MCP_EXECUTABLE)
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/execution", "p")
vim.fn.mkdir(root .. "/outside", "p")
root = require("aero.storage").canonical(root)
local execution = root .. "/execution"
local fixture = vim.fn.getcwd() .. "/tests/fixtures/modes.py"
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	start_insert = false,
	agents = {
		fixture = { type = "acp", cmd = { "python3", fixture, "config" } },
		blocked = { type = "acp", cmd = { "python3", fixture, "config" } },
		terminal = { cmd = { "sh" } },
	},
	tasks = {
		directory = "worktree",
		states = { "todo", "review" },
		agent = {
			enabled = true,
			executable = executable,
			adapters = { "fixture" },
			prompt = "Configured task instructions.",
		},
	},
})
local tasks, agent = require("aero.tasks"), require("aero.tasks.agent")
local sessions, store = require("aero.session"), require("aero.store")
local bridge, git = require("aero.tasks.bridge"), require("aero.git")
local config = require("aero.config").options
local ws = { root = root }
local board = assert(tasks.create_board(ws, "Assignment"))
local first = assert(tasks.create_ticket(ws, board.path, "todo", "First"))
local second = assert(tasks.create_ticket(ws, board.path, "todo", "Second"))
-- Model a workspace with two execution worktrees, separate from an outside session.
local worktrees = { { path = root }, { path = execution } }
git.list = function(path)
	assert(path == root)
	return worktrees
end
require("aero.tasks.ui").workspace = function(callback)
	callback(ws)
end
local s = assert(sessions.create(execution, "fixture", "Existing conversation"))
assert(require("aero.panel").show(s))
assert(vim.wait(5000, function()
	return s.chat and s.chat.state == "ready"
end))
local chat = s.chat
local stopped = assert(sessions.create(root, "fixture", "Stopped"))
local blocked = assert(sessions.create(root, "blocked", "Disallowed adapter"))
local terminal = assert(sessions.create(root, "terminal", "Terminal"))
local outside = assert(sessions.create(root .. "/outside", "fixture", "Other workspace"))
-- Even live-looking sessions cannot bypass workspace, type, or allowlist filtering.
blocked.chat, terminal.chat, outside.chat = chat, chat, chat
local warnings = {}
vim.notify = function(message)
	table.insert(warnings, message)
end
local calls = {}
local original_request = chat.client.request
chat.client.request = function(client, method, params, callback)
	table.insert(calls, { method = method, params = params })
	return original_request(client, method, params, callback)
end
local function work(ticket, on_select, confirm)
	vim.ui.select = function(items, opts, callback)
		if opts.prompt == "Assign ticket to ACP session" then
			assert(items[1] == "New session" and items[2] == "Existing session")
			callback("Existing session")
		elseif opts.prompt == "Existing ACP session for ticket" then
			assert(vim.tbl_contains(items, s), "selected session missing from picker")
			for _, excluded_session in ipairs({ stopped, blocked, terminal, outside }) do
				assert(not vim.tbl_contains(items, excluded_session), "ineligible session leaked into picker")
			end
			local label = opts.format_item(s)
			assert(label:find(s.name, 1, true) and label:find(execution, 1, true))
			if on_select then
				on_select(callback)
			else
				callback(s)
			end
		elseif opts.prompt == "Replace assignment for " .. s.name .. "?" then
			if type(confirm) == "function" then
				confirm(callback)
			else
				callback(confirm == false and "Cancel" or "Replace assignment")
			end
		else
			error("unexpected picker: " .. opts.prompt)
		end
	end
	agent.work(board.metadata.id, ticket.metadata.id)
end
local function draft()
	return table.concat(api.nvim_buf_get_lines(chat:get_prompt_buf(), 0, -1, false), "\n")
end
local function read_credential(transport)
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
		return vim.json.decode(result.stdout)
	end
	assert(result.stderr:find("NOT_FOUND", 1, true), result.stderr)
end
local function settled()
	assert(
		vim.wait(5000, function()
			return not chat.task_pending
		end),
		"task reload did not finish"
	)
end
api.nvim_buf_set_lines(chat:get_prompt_buf(), 0, -1, false, { "Keep this draft." })
chat:append("user", "Existing question")
chat:append("agent", "Existing answer")
chat.usage = { tokens = { total = 42 }, context = { used = 7, size = 100 } }
local function transcript()
	return vim.tbl_map(function(block)
		return { kind = block.kind, text = block.text }
	end, chat.blocks)
end
local history, usage, settings = transcript(), vim.deepcopy(chat.usage), vim.deepcopy(chat.config_options)
local id, key, count = chat.session_id, s.key, #sessions.all()
s.mcp_servers = { { name = "other-server", command = "other", args = {}, env = {} } }
s.runtime_env = { KEEP = "value" }
-- A real ACP session/load, then a real Go MCP call through the ticket binding.
work(first)
settled()
assert(#calls == 1 and calls[1].method == "session/load")
assert(calls[1].params.sessionId == id and calls[1].params.cwd == execution)
assert(#sessions.all() == count and s.key == key and s.worktree == execution and chat.session_id == id)
assert(vim.deep_equal(transcript(), history) and vim.deep_equal(chat.usage, usage))
assert(vim.deep_equal(chat.config_options, settings))
assert(draft():find("Keep this draft.", 1, true) == 1)
assert(draft():find(first.metadata.id, 1, true) and draft():find("Configured task instructions.", 1, true))
assert(s.task_binding.ticket_id == first.metadata.id and s.task_binding.worktree == execution)
assert(vim.tbl_contains(s.task_documents, first.path) and vim.tbl_contains(s.task_documents, board.path))
assert(s.mcp_servers[2].name == "other-server" and s.runtime_env.KEEP == "value")
assert(store.find_session(execution, s.name).task_assignment.ticket_id == first.metadata.id)
assert(read_credential(s.task_transport).ticket_id == first.metadata.id)
local write_error
chat:on_request("fs/write_text_file", { path = first.path, content = "Bypass" }, function(_, err)
	write_error = err
end)
assert(write_error and write_error.message:find("Aero task tools", 1, true))

-- Same-ticket assignment appends instructions without reload or credential rotation.
local old_transport, old_binding = s.task_transport, s.task_binding
local before = draft()
work(first)
assert(#calls == 1 and s.task_transport == old_transport and #draft() > #before)
-- Both cancellation points leave the binding and draft unchanged.
before = draft()
work(second, function(callback)
	callback(nil)
end)
work(second, nil, false)
assert(#calls == 1 and s.task_binding == old_binding and draft() == before)

-- Restrictions are checked before selection, with guidance and zero loads.
local function excluded(object, field, value, expected)
	local n = #calls
	local previous = object[field]
	object[field] = value
	work(second)
	assert(#calls == n and warnings[#warnings]:find(expected, 1, true), warnings[#warnings])
	object[field] = previous
end
excluded(chat, "state", "starting", "ready")
excluded(chat, "busy", true, "idle")
excluded(chat, "task_pending", true, "idle")
excluded(chat, "model_pending", "switching", "idle")
excluded(chat, "mode_pending", "switching", "idle")
excluded(chat.caps, "loadSession", false, "session/load")
excluded(chat, "session_id", "", "resume")
excluded(config.tasks.agent, "adapters", {}, "tasks.agent.adapters")

-- Recheck changes made after picker creation and after replacement confirmation.
local function changed_after_picker(change, restore, expected, confirmation)
	local n = #calls
	local expected_binding = old_binding
	local callback = function(select)
		change()
		expected_binding = s.task_binding
		select(confirmation and "Replace assignment" or s)
	end
	if confirmation then
		work(second, nil, callback)
	else
		work(second, callback)
	end
	assert(#calls == n and s.task_binding == expected_binding and draft() == before)
	assert(warnings[#warnings]:find(expected, 1, true), warnings[#warnings])
	restore()
end
local function changed_field(object, field, value, expected, confirmation)
	local previous = object[field]
	changed_after_picker(function()
		object[field] = value
	end, function()
		object[field] = previous
	end, expected, confirmation)
end
changed_field(chat, "busy", true, "current turn")
changed_field(chat, "task_pending", true, "session change")
changed_field(chat.caps, "loadSession", false, "session/load")
changed_field(chat, "session_id", "", "conversation ID")
changed_field(config.agents.fixture, "type", "terminal", "ACP adapter")
changed_field(config.tasks.agent, "adapters", {}, "tasks.agent.adapters", true)
changed_after_picker(function()
	worktrees = { { path = root } }
end, function()
	worktrees = { { path = root }, { path = execution } }
end, "outside")
changed_field(s, "task_binding", vim.deepcopy(old_binding), "assignment changed", true)
local ticket_buf = vim.fn.bufadd(second.path)
vim.fn.bufload(ticket_buf)
changed_after_picker(function()
	api.nvim_buf_set_lines(ticket_buf, -1, -1, false, { "Unsaved ticket draft" })
end, function()
	vim.bo[ticket_buf].modified = false
	vim.cmd("silent checktime")
end, "save board and ticket drafts", true)
local board_buf = vim.fn.bufadd(board.path)
vim.fn.bufload(board_buf)
changed_after_picker(function()
	api.nvim_buf_set_lines(board_buf, -1, -1, false, { "Unsaved board draft" })
end, function()
	vim.bo[board_buf].modified = false
	vim.cmd("silent checktime")
end, "save board and ticket drafts")

local view = require("aero.tasks.view").open(ws, board.path)
local column = view.columns[1].buf
local column_lines = api.nvim_buf_get_lines(column, 0, -1, false)
changed_after_picker(function()
	api.nvim_buf_set_lines(column, -1, -1, false, { "Unsaved board row" })
end, function()
	api.nvim_buf_set_lines(column, 0, -1, false, column_lines)
	vim.bo[column].modified = false
end, "save board and ticket drafts")

-- Hold a load to test history/settings/usage replay and rollback credential lifetime.
local pending, failed_transport, loads = nil, nil, 0
chat.client.request = function(_, method, params, callback)
	assert(method == "session/load", "assignment submitted a prompt")
	loads = loads + 1
	assert(params.sessionId == id and params.cwd == execution)
	if loads == 1 then
		pending = callback
		failed_transport = s.task_transport
		assert(failed_transport ~= old_transport)
		chat:on_update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Duplicate" } })
		chat:on_update({ sessionUpdate = "current_mode_update", currentModeId = "plan" })
		chat:on_update({ sessionUpdate = "current_model_update", currentModelId = "beta" })
		chat:on_update({ sessionUpdate = "usage_update", used = 99, size = 100 })
	else
		assert(params.mcpServers[1].env[1].value == old_transport.credential)
		assert(params.mcpServers[2].name == "other-server")
		callback(nil, {})
	end
end
work(second)
assert(chat.task_pending and chat.task_reloading and loads == 1)
assert(read_credential(old_transport).ticket_id == first.metadata.id, "old credential revoked before commit")
assert(store.find_session(execution, s.name).task_assignment.ticket_id == first.metadata.id)
pending({ message = "Fixture reload rejected" })
assert(loads == 2 and not chat.task_pending and not chat.task_reloading)
assert(s.task_transport == old_transport and s.task_binding == old_binding and draft() == before)
assert(read_credential(old_transport).ticket_id == first.metadata.id and not read_credential(failed_transport))
assert(
	vim.deep_equal(transcript(), history)
		and vim.deep_equal(chat.usage, usage)
		and vim.deep_equal(chat.config_options, settings)
)
assert(store.find_session(execution, s.name).task_assignment.ticket_id == first.metadata.id)

-- Draft-composition failure also restores provider configuration and the draft.
loads = 0
local compose = require("aero.compose")
local original_append = compose.append
compose.append = function()
	api.nvim_buf_set_lines(chat:get_prompt_buf(), 0, -1, false, { "Partial replacement draft" })
	return nil, "Cannot compose"
end
work(second)
pending(nil, {})
compose.append = original_append
assert(loads == 2 and draft() == before and s.task_binding == old_binding)
assert(not read_credential(failed_transport))

-- Successful replacement rotates credentials only at commit and retains history.
loads = 0
work(second)
local replacement = s.task_transport
assert(read_credential(old_transport).ticket_id == first.metadata.id)
pending(nil, {})
assert(loads == 1 and s.task_transport == replacement and not chat.task_pending)
assert(read_credential(replacement).ticket_id == second.metadata.id and not read_credential(old_transport))
assert(store.find_session(execution, s.name).task_assignment.ticket_id == second.metadata.id)
assert(draft():find(second.metadata.id, 1, true) and chat.session_id == id and s.worktree == execution)
assert(
	vim.deep_equal(transcript(), history)
		and vim.deep_equal(chat.usage, usage)
		and vim.deep_equal(chat.config_options, settings)
)

-- Failure from an unbound session returns to unbound state, without saved identity.
bridge.unbind(replacement.credential)
s.task_binding, s.task_transport, s.task_documents, s.mcp_servers, s.runtime_env = nil, nil, nil, nil, nil
store.set_session_field(execution, s.name, "task_assignment", nil)
loads = 0
chat.client.request = function(_, method, params, callback)
	assert(method == "session/load")
	loads = loads + 1
	if loads == 1 then
		failed_transport = s.task_transport
		callback({ message = "Unbound load rejected" })
	else
		assert(#params.mcpServers == 0)
		callback(nil, {})
	end
end
before = draft()
work(first)
assert(
	loads == 2
		and not s.task_binding
		and not s.task_transport
		and not s.task_documents
		and not s.mcp_servers
		and not s.runtime_env
)
assert(not store.find_session(execution, s.name).task_assignment and draft() == before)
assert(not read_credential(failed_transport))

-- A failed provider recovery stops prompts but keeps the previous saved identity.
assert(agent.attach(s, { workspace = ws, board_id = board.metadata.id, ticket_id = first.metadata.id }, executable))
agent.remember(s)
old_transport, old_binding = s.task_transport, s.task_binding
loads = 0
chat.client.request = function(_, method, _, callback)
	assert(method == "session/load")
	loads = loads + 1
	if loads == 1 then
		failed_transport = s.task_transport
	end
	callback({ message = "Provider unavailable" })
end
work(second)
assert(loads == 2 and chat.state == "exited" and chat.resume_error)
assert(s.task_binding == old_binding and s.task_transport == old_transport)
assert(store.find_session(execution, s.name).task_assignment.ticket_id == first.metadata.id)
assert(not read_credential(failed_transport))
assert(warnings[#warnings]:find("resume", 1, true))
blocked.chat, terminal.chat, outside.chat = nil, nil, nil

-- Deleted sessions are rechecked after selection; never recreate their identity.
local function another_session(name)
	s = assert(sessions.create(execution, "fixture", name))
	assert(require("aero.panel").show(s))
	assert(vim.wait(5000, function()
		return s.chat and s.chat.state == "ready"
	end))
	chat = s.chat
end
another_session("Deleted in picker")
local deleted_name = s.name
loads = 0
chat.client.request = function()
	loads = loads + 1
end
work(first, function(callback)
	sessions.delete(s)
	callback(s)
end)
assert(loads == 0 and not store.find_session(execution, deleted_name))
assert(warnings[#warnings]:find("session no longer exists", 1, true))

-- Deletion during a held load revokes both staged and retained credentials.
another_session("Deleted while loading")
assert(agent.attach(s, { workspace = ws, board_id = board.metadata.id, ticket_id = first.metadata.id }, executable))
agent.remember(s)
old_transport = s.task_transport
deleted_name = s.name
chat.client.request = function(_, method, _, callback)
	assert(method == "session/load")
	pending = callback
end
work(second)
failed_transport = s.task_transport
assert(chat.task_pending and failed_transport ~= old_transport)
sessions.delete(s)
pending(nil, {})
assert(not vim.tbl_contains(sessions.all(), s) and not store.find_session(execution, deleted_name))
assert(not read_credential(failed_transport) and not read_credential(old_transport))
assert(not chat.task_pending)
for _, session in ipairs(sessions.all()) do
	sessions.delete(session)
end
bridge.stop()
vim.fn.delete(root, "rf")
print("Existing-ticket session tests passed (selection, preservation, revalidation, rollback, credentials).")
vim.cmd("qa!")
