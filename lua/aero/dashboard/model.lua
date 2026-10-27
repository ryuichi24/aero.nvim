-- Format a prepared dashboard snapshot. No filesystem reads, Git requests or buffers.
local M = {}
local status_hl = {
	busy = "AeroBusy",
	idle = "AeroIdle",
	waiting = "AeroWaiting",
	exited = "AeroExited",
	stopped = "AeroStopped",
}

function M.worktree_label(worktree)
	return worktree.branch or "(detached " .. (worktree.head or ""):sub(1, 7) .. ")"
end

local function tracking_label(cache, branch)
	if cache.checking then
		return " [checking remote…]", "AeroDim"
	end

	if cache.fetch_err then
		return " [fetch failed]", "AeroExited"
	end

	local tracking = cache.statuses and cache.statuses[branch]

	if not tracking then
		return
	end

	if not tracking.upstream then
		return " [no upstream]", "AeroDim"
	end

	if tracking.gone then
		return " [upstream gone]", "AeroExited"
	end

	if tracking.ahead > 0 and tracking.behind > 0 then
		return string.format(" [diverged ↑%d ↓%d]", tracking.ahead, tracking.behind), "AeroExited"
	end

	if tracking.behind > 0 then
		return string.format(" [pull ↓%d]", tracking.behind), "AeroWaiting"
	end

	if tracking.ahead > 0 then
		return string.format(" [ahead ↑%d]", tracking.ahead), "AeroIdle"
	end

	return " [up to date]", "AeroIdle"
end

function M.build(snapshot)
	local lines, items, marks = {}, {}, {}
	local icons = snapshot.icons

	local function add(segments, item, virt)
		local text, column, highlights = "", 0, {}

		for _, segment in ipairs(segments) do
			if segment[2] then
				table.insert(highlights, { column, column + #segment[1], segment[2] })
			end

			text, column = text .. segment[1], column + #segment[1]
		end

		table.insert(lines, text)
		items[#lines], marks[#lines] = item, { hls = highlights, virt = virt }
	end

	add({ { " Aero", "AeroTitle" }, { "  g? for help", "AeroDim" } })
	add({})

	if #snapshot.workspaces == 0 then
		add({ { "  No workspaces yet. Press ", "AeroDim" }, { snapshot.add_key or "A" }, { " to add one.", "AeroDim" } })
	end

	for _, workspace in ipairs(snapshot.workspaces) do
		local ws, open = workspace.ws, workspace.ws.expanded ~= false
		add(
			{ { " " .. (open and icons.expanded or icons.collapsed) .. " " }, { ws.name, "AeroWorkspace" } },
			{ kind = "workspace", id = "ws:" .. ws.root, ws = ws },
			{ { workspace.display_path, "AeroDim" } }
		)

		if open then
			local cache = workspace.cache

			if cache.err then
				add(
					{ { "     ! " .. cache.err, "AeroExited" } },
					{ kind = "workspace", id = "ws-err:" .. ws.root, ws = ws }
				)
			end

			for _, tree in ipairs(workspace.worktrees) do
				local wt, expanded = tree.wt, tree.expanded
				local segments = {
					{ "   " .. (expanded and icons.expanded or icons.collapsed) .. " " },
					{ tree.basename, "AeroWorktree" },
					{ " (", "AeroBranch" },
					{ wt.branch or "detached " .. (wt.head or ""):sub(1, 7), "AeroBranch" },
					{ ")", "AeroBranch" },
				}

				if wt.branch then
					local label, highlight = tracking_label(cache, wt.branch)

					if label then
						table.insert(segments, { label, highlight })
					end
				end

				local virt = expanded and {} or vim.deepcopy(tree.summary)
				local item = { kind = "worktree", id = "wt:" .. wt.path, ws = ws, wt = wt }
				add(segments, item, virt)

				if expanded then
					if #tree.sessions == 0 then
						add(
							{ { "       no agents — press a to start one", "AeroDim" } },
							vim.tbl_extend("force", item, { id = "wt-empty:" .. wt.path })
						)
					end

					for _, entry in ipairs(tree.sessions) do
						local selected, highlight = entry.session, status_hl[entry.status]
						local details = { { " " .. (entry.activity or entry.status), highlight } }

						if entry.usage then
							table.insert(details, { " · " .. entry.usage, "AeroDim" })
						end

						if selected.name ~= selected.agent then
							table.insert(details, { " " .. selected.agent, "AeroDim" })
						end

						add(
							{ { "     " }, { entry.icon, highlight }, { " " .. selected.name, "AeroSession" } },
							{ kind = "session", id = "s:" .. selected.key, ws = ws, wt = wt, session = selected },
							details
						)
						add({ { "       " .. entry.assignment, "AeroDim" } }, {
							kind = "session",
							id = "assignment:" .. selected.key,
							ws = ws,
							wt = wt,
							session = selected,
						})
					end

					add(
						{
							{ "     " .. (tree.exports_open and icons.expanded or icons.collapsed) .. " " },
							{ "Exported logs", "AeroWorkspace" },
						},
						{ kind = "exports", id = "exports:" .. wt.path, ws = ws, wt = wt },
						{ { " " .. #tree.exports, "AeroDim" } }
					)

					if tree.exports_open then
						for _, log in ipairs(tree.exports) do
							add(
								{ { "       " }, { log.name, "AeroSession" } },
								{ kind = "export", id = "export:" .. log.path, ws = ws, wt = wt, report = log }
							)
						end
					end

					local reading_lists = tree.reading_lists or {}
					add(
						{
							{ "     " .. (tree.reading_open and icons.expanded or icons.collapsed) .. " " },
							{ "Reading lists", "AeroWorkspace" },
						},
						{ kind = "reading", id = "reading:" .. wt.path, ws = ws, wt = wt },
						{ { " " .. #reading_lists, "AeroDim" } }
					)

					if tree.reading_open then
						for _, list in ipairs(reading_lists) do
							local read = 0

							for _, stop in ipairs(list.items) do
								if stop.read then
									read = read + 1
								end
							end

							add({ { "       " }, { list.title:gsub("[%c]", " "), "AeroSession" } }, {
								kind = "reading_list",
								id = "reading-list:" .. wt.path .. ":" .. list.id,
								ws = ws,
								wt = wt,
								reading = list,
							}, { { (" %d/%d read"):format(read, #list.items), "AeroDim" } })
						end

						add(
							{ { "       New reading list +", "AeroDim" } },
							{ kind = "reading_new", id = "reading-new:" .. wt.path, ws = ws, wt = wt }
						)
					end

					local references = tree.references or {}
					add(
						{
							{ "     " .. (tree.reference_open and icons.expanded or icons.collapsed) .. " " },
							{ "References", "AeroWorkspace" },
						},
						{ kind = "reference", id = "reference:" .. wt.path, ws = ws, wt = wt },
						{ { " " .. #references, "AeroDim" } }
					)

					if tree.reference_open then
						if tree.reference_err then
							add({ { "       ! " .. tree.reference_err:gsub("[%c]", " "), "AeroExited" } })
						end

						local function add_references(entries, indent, parent)
							for _, entry in ipairs(entries) do
								local directory = entry.kind == "directory"
								local prefix = directory
										and ((entry.expanded and icons.expanded or icons.collapsed) .. " ")
									or ""
								local id = "reference-item:" .. entry.path
								add({
									{ indent .. prefix },
									{ entry.name:gsub("[%c]", " ") .. (directory and "/" or ""), "AeroSession" },
								}, {
									kind = "reference_item",
									id = id,
									parent = parent,
									ws = ws,
									wt = wt,
									reference = entry,
								})

								if directory and entry.expanded then
									if entry.err then
										add({ { indent .. "  ! " .. entry.err:gsub("[%c]", " "), "AeroExited" } })
									end

									add_references(entry.children or {}, indent .. "  ", id)
								end
							end
						end

						add_references(references, "       ", "reference:" .. wt.path)
						add(
							{ { "       Add +", "AeroDim" } },
							{ kind = "reference_new", id = "reference-new:" .. wt.path, ws = ws, wt = wt }
						)
					end

					add(
						{
							{ "     " .. (tree.reports_open and icons.expanded or icons.collapsed) .. " " },
							{ "Reports", "AeroWorkspace" },
						},
						{ kind = "reports", id = "reports:" .. wt.path, ws = ws, wt = wt },
						{ { " " .. #tree.reports, "AeroDim" } }
					)

					if tree.reports_open then
						if tree.report_err then
							add({ { "       ! " .. tree.report_err:gsub("[\r\n]", " "), "AeroExited" } })
						end

						for _, report in ipairs(tree.reports) do
							add(
								{ { "       " }, { report.name:gsub("[\r\n]", " "), "AeroSession" } },
								{ kind = "report", id = "report:" .. report.path, ws = ws, wt = wt, report = report }
							)
						end

						add(
							{ { "       New +", "AeroDim" } },
							{ kind = "report_new", id = "report-new:" .. wt.path, ws = ws, wt = wt }
						)
					end
				end
			end

			add({
				{ "   " .. (workspace.boards_open and icons.expanded or icons.collapsed) .. " " },
				{ "Boards", "AeroWorkspace" },
			}, { kind = "boards", id = "boards:" .. ws.root, ws = ws }, { { " " .. #workspace.boards, "AeroDim" } })

			if workspace.boards_open then
				for _, entry in ipairs(workspace.boards) do
					local board, data = entry.board, entry.board.metadata or {}
					local description = " " .. board.count .. " tickets" .. (data.archived and " · archived" or "")

					if #board.orphans > 0 then
						description = description .. " · " .. #board.orphans .. " removed"
					end

					if type(data.description) == "string" then
						description = description .. " · " .. data.description:gsub("[%c]", " ")
					end

					if type(data.tags) == "table" then
						description = description .. " · " .. table.concat(vim.tbl_map(tostring, data.tags), ", ")
					end

					if #board.diagnostics > 0 then
						description = description .. " · ! " .. #board.diagnostics
					end

					add(
						{ { "     " }, { entry.label, "AeroSession" } },
						{ kind = "board", id = "board:" .. board.path, ws = ws, board = board },
						{ { description, "AeroDim" } }
					)
				end

				add(
					{ { "     Removed tickets", "AeroSession" } },
					{ kind = "tickets_removed", id = "tickets-removed:" .. ws.root, ws = ws },
					{ { " " .. workspace.removed_count, "AeroDim" } }
				)

				for _, err in ipairs(workspace.board_errors) do
					add({ { "     ! " .. tostring(err):gsub("[%c]", " "), "AeroExited" } })
				end

				add({ { "     New +", "AeroDim" } }, { kind = "board_new", id = "board-new:" .. ws.root, ws = ws })
			end
		end
	end

	return lines, items, marks
end

return M
