local M = {}
local function notify(err)
	vim.notify("Aero tasks: " .. (type(err) == "table" and err.message or tostring(err)), vim.log.levels.WARN)
end

function M.work(board_id, ticket_id)
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
				ws, board_id, ticket_id = selected.workspace, selected.board_id, selected.ticket_id
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
		if not board_id or not ticket_id then
			return notify("select a persisted ticket; save new rows with :w first")
		end
		local binding = { workspace = ws, board_id = board_id, ticket_id = ticket_id }
		local function validate()
			local data, err = require("aero.tasks.operations").get_ticket(binding)
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
				vim.ui.input({ prompt = "Task session name: ", default = ticket_id }, function(name)
					if not name or vim.trim(name) == "" then
						return
					end
					local data = validate()
					if not data then
						return
					end
					local definition = require("aero.config").options.agents[agent]
					if not definition or definition.type ~= "acp" then
						return notify("selected ACP adapter is no longer configured")
					end
					local live = require("aero.git").list(ws.root) or {}
					if not vim.iter(live):any(function(candidate)
						return candidate.path == wt.path
					end) then
						return notify("worktree disappeared")
					end
					local session, create_err = require("aero.session").create(wt.path, agent, vim.trim(name))
					if not session then
						return notify(create_err)
					end
					binding.worktree, binding.session_key = wt.path, session.key
					local transport, bridge_err = require("aero.tasks.bridge").bind(binding)
					if not transport then
						require("aero.session").delete(session)
						return notify(bridge_err)
					end
					session.task_binding = vim.deepcopy(binding)
					session.task_documents = { data.board_path, data.ticket_path }
					session.task_transport = transport
					session.runtime_env =
						{ AERO_TASK_SOCKET = transport.socket, AERO_TASK_CREDENTIAL = transport.credential }
					session.mcp_servers = {
						{
							name = "aero-tasks",
							command = executable,
							args = { "serve", "--socket", transport.socket },
							env = { { name = "AERO_TASK_CREDENTIAL", value = transport.credential } },
						},
					}
					if require("aero.tabs").enabled() then
						require("aero.tabs").enter(wt.path)
					else
						if vim.t.aero_board_path then
							vim.cmd.tabnew()
						end
						vim.cmd.tcd(vim.fn.fnameescape(wt.path))
					end
					local prompt = table.concat({
						"Workspace root: " .. vim.json.encode(ws.root),
						"Board ID: " .. board_id,
						"Board file: " .. vim.json.encode(data.board_path),
						"Ticket ID: " .. ticket_id,
						"Ticket file: " .. vim.json.encode(data.ticket_path),
						"Execution worktree: " .. vim.json.encode(wt.path),
						"",
						config.tasks.agent.prompt,
					}, "\n")
					local ok, compose_err = require("aero.compose").append(session, prompt)
					if not ok then
						require("aero.tasks.bridge").unbind(transport.credential)
						require("aero.session").delete(session)
						notify(compose_err)
					end
				end)
			end)
		end)
	end)
end
return M
