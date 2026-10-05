local M = {}
local function notify(err)
	vim.notify("Aero tasks: " .. (type(err) == "table" and err.message or tostring(err)), vim.log.levels.WARN)
end

function M.remember(session)
	local binding = session.task_binding
	require("aero.store").set_session_field(session.worktree, session.name, "task_assignment", {
		workspace_root = binding.workspace.root,
		board_id = binding.board_id,
		ticket_id = binding.ticket_id,
	})
end

local function saved_assignment(session)
	local store = require("aero.store")
	store.load()
	local definition = store.find_session(session.worktree, session.name)
	if definition and definition.task_assignment ~= nil then
		return definition.task_assignment
	end
	if session.task_binding then
		local binding = session.task_binding
		return { workspace_root = binding.workspace.root, board_id = binding.board_id, ticket_id = binding.ticket_id }
	end
	-- Migrate pre-persistence assignments from Aero's generated initial prompt.
	local history = require("aero.history").load(session)
	for _, block in ipairs(history and history.blocks or {}) do
		if block.kind == "user" and type(block.text) == "string" then
			local root, board = block.text:match("^Workspace root: ([^\n]+)\nBoard ID: ([^\n]+)\nBoard file: ")
			local ticket = block.text:match("\nTicket ID: ([^\n]+)\nTicket file: ")
			if root and board and block.text:find("\nExecution worktree: ", 1, true) then
				local ok, workspace = pcall(vim.json.decode, root)
				if ok and type(workspace) == "string" then
					return { workspace_root = workspace, board_id = board, ticket_id = ticket }
				end
			end
		end
	end
end

-- Rebuild transport state before session/new or session/load, including after restart.
function M.restore(session)
	local assignment = saved_assignment(session)
	if assignment == nil then
		return true
	end
	if
		type(assignment) ~= "table"
		or type(assignment.workspace_root) ~= "string"
		or assignment.workspace_root == ""
		or type(assignment.board_id) ~= "string"
		or assignment.board_id == ""
		or (assignment.ticket_id ~= nil and (type(assignment.ticket_id) ~= "string" or assignment.ticket_id == ""))
	then
		return nil, "invalid saved task assignment"
	end
	local config = require("aero.config").options
	if not config.tasks.agent.enabled then
		return nil, "enable tasks.agent.enabled to resume this task session"
	end
	if not vim.tbl_contains(config.tasks.agent.adapters, session.agent) then
		return nil, "add this adapter to tasks.agent.adapters to resume this task session"
	end
	local executable, err = require("aero.tasks.install").resolve()
	if not executable then
		return nil, err
	end
	local store = require("aero.store")
	local ws = store.find_workspace(assignment.workspace_root) or { root = assignment.workspace_root }
	local ok, attach_err = M.attach(session, {
		workspace = ws,
		board_id = assignment.board_id,
		ticket_id = assignment.ticket_id,
	}, executable)
	if not ok then
		local message = type(attach_err) == "table" and attach_err.message or tostring(attach_err)
		return nil,
			message
				.. " (session: "
				.. session.name
				.. ", board: "
				.. assignment.board_id
				.. (assignment.ticket_id and (", ticket: " .. assignment.ticket_id) or "")
				.. ")"
	end
	M.remember(session)
	return true
end

function M.attach(session, binding, executable)
	local board, board_err = require("aero.tasks").resolve_board(binding.workspace, binding.board_id)
	if not board then
		return nil, board_err
	end
	local ticket
	if binding.ticket_id then
		local err
		ticket, err = require("aero.tasks").resolve_ticket(board, binding.ticket_id)
		if not ticket then
			return nil, err
		end
	end
	binding.worktree, binding.session_key = session.worktree, session.key
	local transport, err = require("aero.tasks.bridge").bind(binding)
	if not transport then
		return nil, err
	end
	if session.task_transport then
		require("aero.tasks.bridge").unbind(session.task_transport.credential)
	end
	session.task_binding = vim.deepcopy(binding)
	session.task_documents = { board.path }
	if ticket then
		table.insert(session.task_documents, ticket.path)
	end
	session.task_transport = transport
	session.runtime_env = { AERO_TASK_SOCKET = transport.socket, AERO_TASK_CREDENTIAL = transport.credential }
	session.mcp_servers = {
		{
			name = "aero-tasks",
			command = executable,
			args = { "serve", "--socket", transport.socket },
			env = { { name = "AERO_TASK_CREDENTIAL", value = transport.credential } },
		},
	}
	return true
end

-- ACP servers are supplied on session/new or session/load, not session/prompt.
function M.prepare_new_ticket(chat, callback)
	if chat.task_pending then
		return
	end
	local config = require("aero.config").options
	if not config.tasks.agent.enabled then
		return notify("enable tasks.agent.enabled to create tickets through MCP")
	end
	if not vim.tbl_contains(config.tasks.agent.adapters, chat.s.agent) then
		return notify("add this ACP adapter to tasks.agent.adapters to use Aero task tools")
	end
	if not chat.caps or not chat.caps.loadSession then
		return notify(
			"this adapter cannot attach MCP to an existing session; start a board session with :Aero board work"
		)
	end
	local executable, err = require("aero.tasks.install").resolve()
	if not executable then
		return notify(err)
	end
	local root = require("aero.git").main_root(chat.s.worktree) or chat.s.worktree
	local ws = require("aero.store").find_workspace(root) or { root = root }
	local tasks = require("aero.tasks")
	local boards = tasks.list(ws)
	local valid = vim.tbl_filter(function(board)
		return board.valid
	end, boards)
	if #valid == 0 then
		return notify("create and save a board with :Aero board new first")
	end
	local function attach(board)
		if not board then
			return
		end
		if chat.state ~= "ready" or chat.busy then
			return notify("wait for the current agent turn to finish, then submit /new-ticket again")
		end
		local ok, attach_err = M.attach(chat.s, { workspace = ws, board_id = board.metadata.id }, executable)
		if not ok then
			return notify(attach_err)
		end
		chat.task_pending = true
		local previous_replay = chat.replay_from_cache
		chat.replay_from_cache = true
		chat.replaying = true
		chat.client:request("session/load", {
			sessionId = chat.session_id,
			cwd = chat.s.worktree,
			mcpServers = chat.s.mcp_servers,
		}, function(load_err)
			chat.task_pending, chat.replaying = false, false
			chat.replay_from_cache = previous_replay
			if load_err then
				require("aero.tasks.bridge").unbind(chat.s.task_transport.credential)
				chat.s.task_binding, chat.s.task_transport, chat.s.task_documents = nil, nil, nil
				chat.s.mcp_servers, chat.s.runtime_env = nil, nil
				notify(load_err)
			else
				M.remember(chat.s)
				callback()
			end
			chat:flush_queue()
		end)
	end
	local current = require("aero.tasks.view").selection()
	for _, board in ipairs(valid) do
		if current and current.workspace.root == root and current.board_id == board.metadata.id then
			return attach(board)
		end
	end
	if #valid == 1 then
		return attach(valid[1])
	end
	vim.ui.select(valid, {
		prompt = "Board for new tickets",
		format_item = function(board)
			return board.metadata.title
		end,
	}, attach)
end

-- Expand Aero's local command before it reaches the ACP provider.
function M.expand_new_ticket(session, text)
	local command, details = vim.trim(text):match("^(%S+)%s*(.*)$")
	if command ~= "/new-ticket" then
		return text
	end
	if
		not session.task_binding
		or session.task_binding.revoked
		or not session.mcp_servers
		or #session.mcp_servers == 0
	then
		return nil, "start a task-enabled session with :Aero board work before using /new-ticket"
	end
	return table.concat({
		"Create a new ticket on the assigned Aero board using Aero's MCP tools.",
		"First call aero_get_board to discover the current board revision and available state names.",
		"Use aero_create_ticket with a unique operation_id, the returned expected_board_revision, a concise title, an existing target_state, and an initial Markdown body containing the description and acceptance criteria.",
		"Use the requested state if specified; otherwise use the board's first state. Derive the ticket content from the request below and our conversation. Ask for clarification if the requirements are unclear.",
		"Set task_type to report for investigation/findings tasks, or implementation for code changes; otherwise omit it to use general.",
		"Do not create or edit task files directly. For retries, reuse the operation_id only with identical arguments. If a revision conflict occurs, reread the board before retrying with a new operation_id. Report the created ticket ID and state. Do not implement the ticket or change the original assigned ticket.",
		"",
		"Ticket request:",
		details ~= "" and details or "Create a ticket for the follow-up discussed in this conversation.",
	}, "\n")
end

local function assignment_prompt(binding, data, worktree, board_only)
	return table.concat({
		"Workspace root: " .. vim.json.encode(binding.workspace.root),
		"Board ID: " .. binding.board_id,
		"Board file: " .. vim.json.encode(data.board_path),
		binding.ticket_id and ("Ticket ID: " .. binding.ticket_id) or "Board-only session: no ticket is assigned.",
		data.ticket_path and ("Ticket file: " .. vim.json.encode(data.ticket_path))
			or "Use /new-ticket to create tickets on this board.",
		"Execution worktree: " .. vim.json.encode(worktree),
		"Read metadata.task_type through aero_get_ticket. If it is report, investigate the ticket and call aero_create_report with a unique operation_id, a filename, and your complete Markdown findings. Record the returned report path in the ticket using aero_update_ticket_body. Reuse an operation_id only for identical retries; existing report files must not be overwritten. A report task calls for findings rather than implementation unless the ticket explicitly requests code changes.",
		"",
		board_only
				and "Use Aero's MCP tools to read this board and create tickets when asked. Do not write task documents directly."
			or require("aero.config").options.tasks.agent.prompt,
	}, "\n")
end

function M.work(board_id, ticket_id, board_only)
	local config = require("aero.config").options
	if not config.tasks.agent.enabled then
		return notify("enable tasks.agent.enabled to assign tickets")
	end
	local executable, executable_err = require("aero.tasks.install").resolve()
	if not executable then
		return notify(executable_err)
	end
	local selected = require("aero.tasks.view").selection()
	require("aero.tasks.ui").workspace(function(ws)
		local tasks = require("aero.tasks")
		if not board_id then
			if selected then
				ws, board_id, ticket_id =
					selected.workspace, selected.board_id, not board_only and selected.ticket_id or nil
			else
				local path = require("aero.storage").canonical(vim.api.nvim_buf_get_name(0))
				for _, board in ipairs(tasks.list(ws)) do
					for _, state in ipairs(board.states) do
						for _, item in ipairs(state.entries) do
							if item.path == path and item.ticket and item.ticket.metadata then
								board_id, ticket_id = board.metadata.id, item.ticket.metadata.id
							end
						end
					end
				end
			end
		end
		if not board_id or (not board_only and not ticket_id) then
			return notify("select a persisted ticket; save new rows with :w first")
		end
		local binding = { workspace = ws, board_id = board_id, ticket_id = ticket_id }
		local function validate()
			local operations = require("aero.tasks.operations")
			local data, err = (board_only and operations.get_board or operations.get_ticket)(binding)
			if data and board_only then
				data.board_path = data.path
			end
			if not data then
				notify(err)
				return
			end
			if data.dirty.board_projection.dirty or data.dirty.board_source or data.dirty.ticket then
				notify("save board and ticket drafts with :w before assigning")
				return
			end
			return data
		end
		if not validate() then
			return
		end
		local function new_session()
			local worktrees, err = require("aero.git").list(ws.root)
			if not worktrees then
				return notify(err)
			end
			vim.ui.select(worktrees, {
				prompt = "Execution worktree",
				format_item = function(wt)
					return wt.path
				end,
			}, function(wt)
				if not wt then
					return
				end
				local agents = {}
				for name, def in pairs(config.agents) do
					if def.type == "acp" and vim.tbl_contains(config.tasks.agent.adapters, name) then
						table.insert(agents, name)
					end
				end
				table.sort(agents)
				vim.ui.select(agents, { prompt = "New task-enabled ACP session" }, function(agent)
					if not agent then
						return
					end
					vim.ui.input({ prompt = "Task session name: ", default = ticket_id or board_id }, function(name)
						if not name or vim.trim(name) == "" then
							return
						end
						local data = validate()
						if not data then
							return
						end
						local definition = require("aero.config").options.agents[agent]
						if
							not definition
							or definition.type ~= "acp"
							or not vim.tbl_contains(require("aero.config").options.tasks.agent.adapters, agent)
						then
							return notify(
								"selected ACP adapter is no longer configured or allowed by tasks.agent.adapters"
							)
						end
						local live = require("aero.git").list(ws.root) or {}
						if
							not vim.iter(live):any(function(candidate)
								return candidate.path == wt.path
							end)
						then
							return notify("worktree disappeared")
						end
						local session, create_err = require("aero.session").create(wt.path, agent, vim.trim(name))
						if not session then
							return notify(create_err)
						end
						local attached, bridge_err = M.attach(session, binding, executable)
						if not attached then
							require("aero.session").delete(session)
							return notify(bridge_err)
						end
						M.remember(session)
						if require("aero.tabs").enabled() then
							require("aero.tabs").enter(wt.path)
						else
							if vim.t.aero_board_path or vim.t.aero_removed_workspace then
								vim.cmd.tabnew()
							end
							vim.cmd.tcd(vim.fn.fnameescape(wt.path))
						end
						local prompt = assignment_prompt(binding, data, wt.path, board_only)
						local ok, compose_err = require("aero.compose").append(session, prompt)
						if not ok then
							require("aero.tasks.bridge").unbind(session.task_transport.credential)
							require("aero.session").delete(session)
							notify(compose_err)
						end
					end)
				end)
			end)
		end
		if board_only then
			return new_session()
		end
		vim.ui.select(
			{ "New session", "Existing session" },
			{ prompt = "Assign ticket to ACP session" },
			function(choice)
				if choice == "New session" then
					new_session()
				elseif choice == "Existing session" then
					require("aero.tasks.assignment").pick(binding, executable, validate, function(data, worktree)
						return assignment_prompt(binding, data, worktree, false)
					end)
				end
			end
		)
	end)
end
return M
