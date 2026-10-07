-- Attach tickets transactionally to live or strictly resumed ACP conversations.
local M = {}
local fields = { "task_binding", "task_transport", "task_documents", "mcp_servers", "runtime_env" }

local function notify(err)
	vim.notify("Aero tasks: " .. (type(err) == "table" and err.message or tostring(err)), vim.log.levels.WARN)
end

local function copy_fields(target, source)
	for _, field in ipairs(fields) do
		target[field] = source[field]
	end
end

local function present(session)
	return vim.tbl_contains(require("aero.session").all(), session)
end

local function definition(session)
	return require("aero.store").find_session(session.worktree, session.name) or {}
end

local function current_binding(session)
	if session.task_binding then
		return session.task_binding
	end
	local saved = definition(session).task_assignment
	if type(saved) == "table" then
		return { workspace = { root = saved.workspace_root }, board_id = saved.board_id, ticket_id = saved.ticket_id }
	end
end

local function eligible(session, worktrees)
	local config = require("aero.config").options
	if not config.tasks.agent.enabled then
		return nil, "enable tasks.agent.enabled to assign tickets"
	end
	if not present(session) then
		return nil, "session no longer exists"
	end
	local adapter = config.agents[session.agent]
	if not adapter or adapter.type ~= "acp" or not vim.tbl_contains(config.tasks.agent.adapters, session.agent) then
		return nil, "select an ACP adapter allowed by tasks.agent.adapters"
	end
	if
		not vim.iter(worktrees):any(function(wt)
			return wt.path == session.worktree and not wt.prunable and vim.fn.isdirectory(wt.path) == 1
		end)
	then
		return nil, "session worktree disappeared or is outside the ticket's workspace"
	end
	local chat = session.chat
	if session.task_assignment_pending then
		return nil, "wait for the current ticket assignment to finish, then assign the ticket again"
	end
	if not chat or chat.state == "exited" or (chat.client and chat.client.closed) then
		local saved = definition(session)
		local history = require("aero.history").load(session)
		local id = saved.acp_session_id or (chat and chat.session_id) or (history and history.session_id)
		if type(id) ~= "string" or id == "" then
			return nil,
				"this session has no saved ACP conversation ID; start a conversation first or choose New session"
		end
		return "stopped", id
	end
	if chat.state ~= "ready" or not chat.client or session.stop_requested then
		return nil, "wait until this session is ready or fully stopped, then assign the ticket again"
	end
	if type(chat.session_id) ~= "string" or chat.session_id == "" then
		return nil, "resume a session with an existing ACP conversation ID first"
	end
	if not chat.caps or not chat.caps.loadSession then
		return nil, "this adapter does not support session/load; choose a new session or a supported adapter"
	end
	if chat.busy or chat.permission or chat.model_pending or chat.mode_pending or chat.task_pending then
		return nil, "wait for the current turn or session change to finish, then assign the ticket again"
	end
	return "ready", chat.session_id
end

local function same_binding(a, b)
	return a
		and not a.revoked
		and a.workspace.root == b.workspace.root
		and a.board_id == b.board_id
		and a.ticket_id == b.ticket_id
end

local function enter(session)
	if require("aero.tabs").enabled() then
		require("aero.tabs").enter(session.worktree)
	else
		if vim.t.aero_board_path or vim.t.aero_removed_workspace then
			vim.cmd.tabnew()
		end
		vim.cmd.tcd(vim.fn.fnameescape(session.worktree))
	end
end

local function append(session, prompt)
	enter(session)
	return require("aero.compose").append(session, prompt)
end

local function stage(session, binding, executable)
	local previous = {}
	copy_fields(previous, session)
	-- Stage with no old transport so attach cannot revoke the rollback credential.
	local staged = { key = session.key, worktree = session.worktree }
	local ok, err = require("aero.tasks.agent").attach(staged, vim.deepcopy(binding), executable)
	if not ok then
		return nil, nil, err
	end
	for _, server in ipairs(previous.mcp_servers or {}) do
		if server.name ~= "aero-tasks" then
			table.insert(staged.mcp_servers, vim.deepcopy(server))
		end
	end
	staged.runtime_env = vim.tbl_extend("force", previous.runtime_env or {}, staged.runtime_env)
	return staged, previous
end

local function resume_stopped(session, session_id, binding, executable, prompt)
	local staged, previous, err = stage(session, binding, executable)
	if not staged then
		return notify(err)
	end
	copy_fields(session, staged)
	session.task_assignment_pending = true
	local function rollback(chat, reason)
		require("aero.tasks.bridge").unbind(staged.task_transport.credential)
		if chat then
			chat.task_pending = false
			chat.state = "exited"
			chat:stop()
		end
		if present(session) then
			copy_fields(session, previous)
		elseif previous.task_transport then
			require("aero.tasks.bridge").unbind(previous.task_transport.credential)
		end
		session.task_assignment_pending = nil
		notify(reason)
	end
	local function on_resume(chat, resume_err)
		if resume_err then
			return rollback(chat, resume_err)
		end
		if not present(session) or session.chat ~= chat or session.stop_requested then
			return rollback(chat, "session stopped or disappeared during assignment; assign it again")
		end
		local buf = chat:get_prompt_buf()
		local draft = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local modified = vim.bo[buf].modified
		local composed, result, compose_err = pcall(append, session, prompt)
		if not composed or not result then
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, draft)
				vim.bo[buf].modified = modified
			end
			return rollback(chat, composed and compose_err or result)
		end
		require("aero.tasks.agent").remember(session)
		if previous.task_transport then
			require("aero.tasks.bridge").unbind(previous.task_transport.credential)
		end
		session.task_assignment_pending, chat.task_pending = nil, false
	end
	-- Explicit ID forbids session/new fallback. Supply the staged tools before load;
	-- restoring the saved (old) task assignment here would overwrite the new binding.
	local started, start_err = pcall(function()
		enter(session)
		return require("aero.session").start(session, vim.api.nvim_get_current_win(), true, session_id, {
			restore_tasks = false,
			on_resume = on_resume,
		})
	end)
	if not started or not start_err then
		rollback(
			session.chat,
			started and "could not resume this ACP session; check the adapter configuration" or start_err
		)
	end
end

local function reload(session, binding, executable, prompt, callback)
	local chat = session.chat
	local staged, previous, err = stage(session, binding, executable)
	if not staged then
		if callback then
			return callback(nil, err)
		end
		return notify(err)
	end
	copy_fields(session, staged)
	local replaying, replay_from_cache = chat.replaying, chat.replay_from_cache
	chat.task_pending, chat.task_reloading = true, true
	chat.replaying, chat.replay_from_cache = true, true
	chat:changed()
	local session_id, client = chat.session_id, chat.client
	local function active()
		return present(session)
			and session.chat == chat
			and chat.state == "ready"
			and chat.client == client
			and not client.closed
			and not session.stop_requested
	end
	local function finish()
		chat.task_pending, chat.task_reloading = false, false
		chat.replaying, chat.replay_from_cache = replaying, replay_from_cache
		if active() then
			chat:changed()
			chat:flush_queue()
		end
	end
	local function rollback(reason)
		if callback then
			callback(nil, reason)
			callback = nil
		end
		require("aero.tasks.bridge").unbind(staged.task_transport.credential)
		if not present(session) or session.chat ~= chat then
			if previous.task_transport then
				require("aero.tasks.bridge").unbind(previous.task_transport.credential)
			end
			return finish()
		end
		copy_fields(session, previous)
		notify(reason)
		if not active() then
			return finish()
		end
		-- A failed load may have changed provider-side MCP state. Restore it too.
		client:request("session/load", {
			sessionId = session_id,
			cwd = session.worktree,
			mcpServers = previous.mcp_servers or {},
		}, function(restore_err)
			if restore_err and active() then
				-- Keep the saved identity; don't run prompts against uncertain provider state.
				chat.resume_error = restore_err
				chat.state = "exited"
				chat:stop()
				notify(
					"previous assignment restored locally, but provider reload failed; resume the session with r in the dashboard"
				)
			end
			finish()
		end)
	end
	client:request("session/load", {
		sessionId = session_id,
		cwd = session.worktree,
		mcpServers = staged.mcp_servers,
	}, function(load_err)
		if load_err then
			return rollback(load_err)
		end
		if not active() then
			return rollback("session stopped or disappeared during assignment; resume it before assigning again")
		end
		local buf = chat:get_prompt_buf()
		local draft = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
		local modified = vim.bo[buf].modified
		local composed, result, compose_err = true, true, nil
		if prompt then
			composed, result, compose_err = pcall(append, session, prompt)
		end
		if not composed or not result then
			if vim.api.nvim_buf_is_valid(buf) then
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, draft)
				vim.bo[buf].modified = modified
			end
			return rollback(composed and compose_err or result)
		end
		require("aero.tasks.agent").remember(session)
		if previous.task_transport then
			require("aero.tasks.bridge").unbind(previous.task_transport.credential)
		end
		finish()
		if callback then
			callback(true)
		end
	end)
end

-- Explicit, picker-free assignment for a remotely selected idle conversation.
function M.assign_board(session, workspace, board_id, replace, callback)
	local binding = { workspace = workspace, board_id = board_id }
	local worktrees, err = require("aero.git").list(workspace.root)
	if not worktrees then
		return callback(nil, err)
	end
	local state, reason = eligible(session, worktrees)
	if state ~= "ready" then
		return callback(nil, state == "stopped" and "resume the session before assigning a board" or reason)
	end
	local previous = current_binding(session)
	if previous and not same_binding(previous, binding) and not replace then
		return callback(nil, "confirm replacement of the current board or ticket assignment")
	end
	local data, read_err = require("aero.tasks.operations").get_board(binding)
	if not data then
		return callback(nil, read_err)
	end
	if data.dirty.board_projection.dirty or data.dirty.board_source then
		return callback(nil, "save board drafts with :w before assigning")
	end
	if same_binding(session.task_binding, binding) and session.task_transport then
		return callback(true)
	end
	local executable, executable_err = require("aero.tasks.install").resolve()
	if not executable then
		return callback(nil, executable_err)
	end
	reload(session, binding, executable, nil, callback)
end

function M.pick(binding, executable, validate, prompt)
	require("aero.store").load()
	local worktrees, err = require("aero.git").list(binding.workspace.root)
	if not worktrees then
		return notify(err)
	end
	local candidates, states = {}, {}
	for _, session in ipairs(require("aero.session").all()) do
		local state = eligible(session, worktrees)
		if state then
			states[session] = state
			table.insert(candidates, session)
		end
	end
	table.sort(candidates, function(a, b)
		return a.worktree .. a.name < b.worktree .. b.name
	end)
	if #candidates == 0 then
		return notify(
			"no eligible ACP sessions: use a saved conversation in this workspace (stopped sessions resume automatically), wait for active sessions to be ready and idle, and use an adapter in tasks.agent.adapters with session/load support; or choose New session"
		)
	end
	vim.ui.select(candidates, {
		prompt = "Existing ACP session for ticket",
		format_item = function(session)
			local status = states[session] == "stopped" and "stopped — resume" or "ready"
			return session.name .. " (" .. session.agent .. ", " .. status .. ") · " .. session.worktree
		end,
	}, function(session)
		if not session then
			return
		end
		local selected_chat, selected_binding = session.chat, session.task_binding
		local selected_assignment = vim.deepcopy(definition(session).task_assignment)
		local function assign()
			local data = validate()
			if not data then
				return
			end
			local live, list_err = require("aero.git").list(binding.workspace.root)
			if not live then
				return notify(list_err)
			end
			local state, id = eligible(session, live)
			if not state then
				return notify(id)
			end
			if
				session.chat ~= selected_chat
				or session.task_binding ~= selected_binding
				or not vim.deep_equal(selected_assignment, definition(session).task_assignment)
			then
				return notify("session or assignment changed while selecting; assign the ticket again")
			end
			local instruction = prompt(data, session.worktree)
			if state == "stopped" then
				resume_stopped(session, id, binding, executable, instruction)
			elseif same_binding(session.task_binding, binding) and session.task_transport then
				local ok, append_err = append(session, instruction)
				if not ok then
					notify(append_err)
				end
			else
				reload(session, binding, executable, instruction)
			end
		end
		local previous_binding = current_binding(session)
		if previous_binding and not same_binding(previous_binding, binding) then
			vim.ui.select({ "Cancel", "Replace assignment" }, {
				prompt = "Replace assignment for " .. session.name .. "?",
			}, function(choice)
				if choice == "Replace assignment" then
					assign()
				end
			end)
		else
			assign()
		end
	end)
end

return M
