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

function M.board(action, ws)
	if action == "new" then
		return M.new_board(ws)
	end
	if action and action ~= "" then
		notify("use :Aero board [new]")
		return
	end
	local function pick(workspace)
		local boards, diagnostics = tasks.list(workspace)
		if #boards == 0 then
			if #diagnostics > 0 then
				notify(table.concat(diagnostics, "\n"))
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
		}, function(board)
			if board then
				require("aero.tasks.view").open(workspace, board.path)
			end
		end)
	end
	if ws then
		return pick(ws)
	end
	return M.workspace(pick)
end

function M.ticket(action)
	local view = require("aero.tasks.view")
	if action == "new" then
		return view.new_ticket()
	end
	if action == "move" then
		return view.move()
	end
	notify("use :Aero ticket new or :Aero ticket move on an active board")
end

return M
