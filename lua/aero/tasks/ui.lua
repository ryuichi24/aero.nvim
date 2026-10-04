local tasks = require("aero.tasks")
local M = {}
local function notify(message)
	vim.notify("Aero tasks: " .. tostring(message), vim.log.levels.WARN)
end

function M.workspace(callback)
	local selected = require("aero.dashboard").selected_workspace()
	if selected then
		callback(selected)
		return
	end
	local root = vim.b.aero_workspace_root
	local view = require("aero.tasks.view").current()
	if root then
		callback({ root = root })
		return
	end
	local cwd = vim.t.aero_worktree or vim.fn.getcwd()
	local main = require("aero.git").main_root(cwd)
	if main then
		callback(require("aero.store").find_workspace(main) or { root = main })
		return
	end
	if view then
		callback(view.ws)
		return
	end
	local workspaces = require("aero.store").data.workspaces
	if #workspaces == 1 then
		callback(workspaces[1])
		return
	end
	if #workspaces == 0 then
		notify("add a workspace or enter a Git repository first")
		return
	end
	vim.ui.select(workspaces, {
		prompt = "Workspace for boards",
		format_item = function(ws)
			return ws.name .. " · " .. ws.root
		end,
	}, function(ws)
		if ws then
			callback(ws)
		end
	end)
end

function M.new_board(ws)
	if not ws then
		return M.workspace(M.new_board)
	end
	vim.ui.input({ prompt = "New board title: " }, function(name)
		if not name or vim.trim(name) == "" then
			return
		end
		local board, err = tasks.create_board(ws, vim.trim(name))
		if not board then
			notify(err)
			return
		end
		require("aero.dashboard").render()
		require("aero.tasks.view").open(ws, board.path)
	end)
end

function M.board(action, ws, board_id)
	if action == "work" then
		local agent = require("aero.tasks.agent")
		if board_id or require("aero.tasks.view").selection() then
			return agent.work(board_id, nil, true)
		end
		return M.workspace(function(workspace)
			local boards = vim.tbl_filter(function(board)
				return board.valid
			end, tasks.list(workspace))
			if #boards == 0 then
				return notify("create and save a board first")
			end
			local function work(board)
				if board then
					agent.work(board.metadata.id, nil, true)
				end
			end
			if #boards == 1 then
				return work(boards[1])
			end
			vim.ui.select(boards, {
				prompt = "Board for agent",
				format_item = function(board)
					return board.metadata.title
				end,
			}, work)
		end)
	end
	if action == "new" then
		return M.new_board(ws)
	end
	local markdown = action == "markdown"
	if action and action ~= "" and not markdown then
		notify("use :Aero board [new|markdown]")
		return
	end
	if markdown and not ws and not board_id then
		local dashboard = require("aero.dashboard")
		if dashboard.open_board_markdown() then
			return
		end
		local viewmod = require("aero.tasks.view")
		local view = viewmod.current()
		if
			not dashboard.selected_workspace()
			and view
			and (vim.b.aero_board_path == view.path or view.tab == vim.api.nvim_get_current_tabpage())
		then
			return viewmod.actions(view).source()
		end
	end
	local function pick(workspace)
		local boards, diagnostics = tasks.list(workspace)
		local function open(board)
			if not board then
				return
			end
			if markdown then
				local viewmod = require("aero.tasks.view")
				local view = viewmod.current()
				if view and view.path == board.path and view.tab == vim.api.nvim_get_current_tabpage() then
					return viewmod.actions(view).source()
				end
				vim.api.nvim_set_current_win(require("aero.dashboard").code_window())
				vim.cmd.edit(vim.fn.fnameescape(board.path))
				vim.b.aero_board_path, vim.b.aero_workspace_root = board.path, workspace.root
			else
				require("aero.tasks.view").open(workspace, board.path)
			end
		end
		if board_id then
			local match
			for _, board in ipairs(boards) do
				if board.metadata and board.metadata.id == board_id then
					if match then
						notify("duplicate board ID: " .. board_id)
						return
					end
					match = board
				end
			end
			if not match then
				notify("board ID not found in this workspace: " .. board_id)
				return
			end
			return open(match)
		end
		if #boards == 0 then
			if #diagnostics > 0 then
				notify(table.concat(diagnostics, "\n"))
				return
			end
			if markdown then
				notify("no boards in this workspace")
				return
			end
			return M.new_board(workspace)
		end
		vim.ui.select(boards, {
			prompt = "Workspace boards",
			format_item = function(board)
				local data = board.metadata or {}
				return tostring(data.title or board.path)
					.. " · "
					.. board.count
					.. " tickets"
					.. (data.archived and " [archived]" or "")
					.. (type(data.description) == "string" and " · " .. data.description or "")
					.. (
						type(data.tags) == "table"
							and " · " .. table.concat(vim.tbl_map(tostring, data.tags), ", ")
						or ""
					)
			end,
		}, open)
	end
	if ws then
		return pick(ws)
	end
	return M.workspace(pick)
end

--- Completion never prompts or creates boards.
function M.board_ids(prefix)
	local ws = require("aero.dashboard").selected_workspace()
	local root = vim.b.aero_workspace_root or require("aero.git").main_root(vim.t.aero_worktree or vim.fn.getcwd())
	ws = ws or root and { root = root }
	if not ws then
		return {}
	end
	local ids = {}
	for _, board in ipairs(tasks.list(ws)) do
		local id = board.metadata and board.metadata.id
		if type(id) == "string" and vim.startswith(id, prefix) then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

function M.removed(ws, preferred_board)
	if not ws then
		local selected = require("aero.dashboard").selected_workspace()
		if selected then
			return M.removed(selected)
		end
		local view = require("aero.tasks.view").current()
		if view then
			return M.removed(view.ws, view.path)
		end
		return M.workspace(function(workspace)
			M.removed(workspace)
		end)
	end
	local removed, diagnostics = tasks.list_removed(ws)
	if #removed == 0 then
		vim.notify(
			"Aero tasks: "
				.. (#diagnostics > 0 and table.concat(diagnostics, "; ") or "no removed tickets in this workspace")
		)
		return
	end
	local edit = require("aero.tasks.edit")
	return require("aero.tasks.removed").open(ws, function(item, refresh)
		if not item then
			return
		end
		if item.error then
			return notify(item.path .. ": " .. item.error)
		end
		local boards = vim.tbl_filter(function(board)
			return board.valid
		end, tasks.list(ws))
		if preferred_board then
			for index, board in ipairs(boards) do
				if board.path == preferred_board then
					table.remove(boards, index)
					table.insert(boards, 1, board)
					break
				end
			end
		end
		vim.ui.select(boards, {
			prompt = "Restore into board",
			format_item = function(board)
				return edit.title(board.metadata.title) .. (board.metadata.archived and " [archived]" or "")
			end,
		}, function(board)
			if not board then
				return
			end
			vim.ui.select(
				vim.tbl_map(function(state)
					return state.name
				end, board.states),
				{ prompt = "Restore into state" },
				function(state)
					if not state then
						return
					end
					if vim.fn.getcmdwintype() ~= "" then
						return notify("close the command window before restoring tickets")
					end
					local result, err = tasks.recover_ticket(ws, item.board_path, item.path, board.path, state, {
						expected_ticket_id = item.ticket.metadata.id,
						guard = function(source, target)
							if source.metadata.id ~= item.board_id or target.metadata.id ~= board.metadata.id then
								return nil, "board identity changed; reload the removed-ticket list"
							end
							for _, path in ipairs({ source.path, target.path }) do
								local status = require("aero.tasks.view").status(path)
								if status.dirty or status.missing_column then
									return nil, "save or discard board edits before restoring tickets: " .. path
								end
							end
							return true
						end,
					})
					-- Also refresh after partial failures that deliberately retain a recovery copy.
					for _, path in ipairs({ item.board_path, board.path }) do
						vim.api.nvim_exec_autocmds("User", {
							pattern = "AeroTaskChanged",
							data = {
								workspace = ws,
								board_path = path,
								ticket_path = result and result.path or item.path,
							},
						})
					end
					if not result then
						return notify(err)
					end
					if result.warning then
						notify(result.warning)
					end
					refresh()
					vim.notify(
						"Aero tasks: restored "
							.. edit.title(item.title)
							.. " to "
							.. edit.title(board.metadata.title)
							.. " / "
							.. state
					)
				end
			)
		end)
	end)
end

function M.ticket(action)
	if action == "removed" or action == "recover" then
		return M.removed()
	end
	if action == "work" then
		return require("aero.tasks.agent").work()
	end
	local view = require("aero.tasks.view")
	if action == "new" then
		return view.new_ticket()
	end
	if action == "move" then
		return view.move()
	end
	notify("use :Aero ticket new, move, work, or removed")
end

return M
