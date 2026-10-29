-- Prepare dashboard data from feature services. The controller owns expansion/cache
-- state and supplies the callback used when asynchronous repository discovery finishes.
local config = require("aero.config")
local session = require("aero.session")
local spinner = require("aero.spinner")
local M = {}
local status_hl = {
	busy = "AeroBusy",
	idle = "AeroIdle",
	waiting = "AeroWaiting",
	exited = "AeroExited",
	stopped = "AeroStopped",
}

function M.worktree_expanded(state, worktree, sessions)
	local expanded = state.expanded[worktree.path]

	if expanded == nil then
		return #sessions > 0
	end

	return expanded
end

local function summary(sessions)
	local counts, order = {}, { "waiting", "busy", "idle", "exited", "stopped" }

	for _, s in ipairs(sessions) do
		local status = session.status(s)
		counts[status] = (counts[status] or 0) + 1
	end

	local chunks = {}

	for _, status in ipairs(order) do
		if counts[status] then
			local icon = status == "busy" and spinner.frame() or config.options.icons[status]
			table.insert(chunks, { " " .. icon .. counts[status], status_hl[status] })
		end
	end

	return chunks
end

local function reference_children(entries, expanded)
	for _, entry in ipairs(entries) do
		if entry.kind == "directory" then
			entry.expanded = expanded[entry.path] == true

			if entry.expanded then
				entry.children = {}
				local scan, err = vim.uv.fs_scandir(entry.path)
				entry.err = err

				if scan then
					while true do
						local name, kind = vim.uv.fs_scandir_next(scan)

						if not name then
							break
						end

						table.insert(
							entry.children,
							{ name = name, kind = kind, path = vim.fs.joinpath(entry.path, name) }
						)
					end
					table.sort(entry.children, function(a, b)
						return a.name < b.name
					end)
					reference_children(entry.children, expanded)
				end
			end
		end
	end
end

--- Prepare a full snapshot, including expanded filesystem-backed sections.
--- Does not own controller state or update editor buffers.
function M.prepare(workspaces, state, on_repository_changed)
	local snapshot = { icons = config.options.icons, add_key = config.options.keymaps.add_workspace, workspaces = {} }

	local function prepare(ws, ancestors, supplied_cache)
		local workspace =
			{ ws = ws, display_path = " " .. vim.fn.fnamemodify(ws.root, ":~"), worktrees = {}, boards = {} }

		if ws.expanded ~= false then
			workspace.cache = supplied_cache or state.worktrees[ws.root] or { list = {} }

			if workspace.cache.list then
				local remote = require("aero.remote_status").peek(ws.root)
				workspace.cache.checking = remote.checking
				workspace.cache.statuses, workspace.cache.fetch_err = remote.statuses, remote.fetch_err
			end

			for _, wt in ipairs(workspace.cache.list or {}) do
				local sessions = session.list(wt.path)
				local tree = {
					wt = wt,
					basename = vim.fs.basename(wt.path),
					expanded = M.worktree_expanded(state, wt, sessions),
					summary = summary(sessions),
					sessions = {},
					exports = {},
					reports = {},
				}
				table.insert(workspace.worktrees, tree)

				if tree.expanded then
					tree.submodules_open = state.submodules_expanded[wt.path] == true
					tree.submodules = {}

					if tree.submodules_open then
						local modules = require("aero.submodules")
						local discovered = modules.entries(wt.path, on_repository_changed)
						tree.submodules_loading, tree.submodules_err = discovered.loading, discovered.err

						for _, entry in ipairs(discovered.list or {}) do
							local child = vim.tbl_extend("force", entry, {
								initialized = modules.initialized(entry.path),
								expanded = state.repositories_expanded[entry.path] == true,
							})
							table.insert(tree.submodules, child)

							if child.initialized and child.expanded and not ancestors[entry.path] then
								local visited = vim.tbl_extend("force", ancestors, { [entry.path] = true })
								local cache = modules.worktrees(entry.path, on_repository_changed)
								child.loading = cache.loading
								local root = cache.list and cache.list[1] and cache.list[1].path or entry.path
								child.workspace = prepare(
									{ root = root, name = entry.name, submodule_checkout = entry.path },
									visited,
									cache
								)
							end
						end
					end

					for _, selected in ipairs(sessions) do
						table.insert(tree.sessions, {
							session = selected,
							status = session.status(selected),
							icon = session.icon(selected),
							activity = session.activity(selected),
							usage = require("aero.acp.usage").summary(selected.chat),
							assignment = require("aero.tasks.status").label(selected),
						})
					end

					tree.exports = require("aero.exports").list(wt.path)
					tree.exports_open = state.exports_expanded[wt.path] ~= false
					tree.reports, tree.report_err = require("aero.reports").list(wt.path, ws)
					tree.reports_open = state.reports_expanded[wt.path] ~= false
					tree.reading_lists = require("aero.reading").list(wt.path)
					tree.reading_open = state.reading_expanded[wt.path] ~= false
					tree.references, tree.reference_err = require("aero.reference").list(wt.path)
					tree.reference_open = state.reference_expanded[wt.path] ~= false

					if tree.reference_open then
						reference_children(tree.references, state.reference_folders_expanded)
					end
				end
			end

			if supplied_cache then
				workspace.board_errors = {}
				return workspace
			end

			local boards
			boards, workspace.board_errors = require("aero.tasks").list(ws)
			workspace.boards_open = state.boards_expanded[ws.root] ~= false
			workspace.removed_count = workspace.boards_open and #require("aero.tasks").list_removed(ws) or 0

			for _, board in ipairs(boards) do
				table.insert(workspace.boards, {
					board = board,
					label = tostring((board.metadata or {}).title or vim.fs.basename(vim.fs.dirname(board.path))):gsub(
						"[%c]",
						" "
					),
				})
			end
		end

		return workspace
	end

	for _, ws in ipairs(workspaces) do
		table.insert(snapshot.workspaces, prepare(ws, { [ws.root] = true }))
	end

	return snapshot
end

--- Refresh live session fields without rescanning files or task metadata.
function M.refresh_sessions(snapshot)
	local function update(workspace)
		for _, tree in ipairs(workspace.worktrees) do
			tree.summary = summary(session.list(tree.wt.path))

			for _, item in ipairs(tree.sessions) do
				item.status = session.status(item.session)
				item.icon = session.icon(item.session)
				item.activity = session.activity(item.session)
				item.usage = require("aero.acp.usage").summary(item.session.chat)
			end

			for _, child in ipairs(tree.submodules or {}) do
				if child.workspace then
					update(child.workspace)
				end
			end
		end
	end

	for _, workspace in ipairs(snapshot.workspaces) do
		update(workspace)
	end
end

return M
