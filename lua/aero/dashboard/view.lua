-- Apply prepared tree rows to a dashboard buffer, retaining selection by identity.
local api = vim.api
local M = {}
local ns = api.nvim_create_namespace("Aero")
local context_ns = api.nvim_create_namespace("AeroSidebarContext")

-- Document identities survive reader-slot changes and do not depend on chat scope.
local function knowledge_documents(state)
	local active = {}
	local catalog = state.knowledge_catalog or { spaces = {} }

	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		local buf = api.nvim_win_get_buf(win)
		local context = vim.b[buf].aero_knowledge_context

		if context and api.nvim_win_get_config(win).relative == "" then
			active["knowledge-group"] = true
			active["knowledge-space:" .. context.space_id] = true
			active["knowledge-" .. context.section:lower() .. ":" .. context.space_id] = true

			if context.note_id then
				active["knowledge-note:" .. context.note_id] = true
				active["knowledge-notes:" .. context.space_id] = true
			end

			if context.source_id then
				active["knowledge-source:" .. context.source_id] = true
				active["knowledge-sources:" .. context.space_id] = true
			end

			for _, space in ipairs(catalog.spaces or {}) do
				if space.id == context.space_id then
					active["knowledge-collection:" .. space.collection_id] = true

					for _, source in ipairs(space.sources or {}) do
						if source.id == context.source_id then
							if source.folder_id then
								active["knowledge-folder:" .. source.folder_id] = true
							end

							local parts = vim.split(source.relative_path or source.name or "", "/", { plain = true })
							local path = ""

							for index = 1, #parts - 1 do
								path = path .. "/" .. parts[index]
								active["knowledge-directory:" .. space.id .. ":" .. path] = true
							end
						end
					end

					for _, record in
						ipairs(vim.list_extend(vim.list_extend({}, space.sources or {}), space.notes or {}))
					do
						if record.id == context.source_id or record.id == context.note_id then
							for _, tag in ipairs(record.tags or {}) do
								active["knowledge-tag:" .. space.id .. ":" .. tag] = true
								active["knowledge-tags:" .. space.id] = true
							end
						end
					end
				end
			end
		end
	end

	-- Follow every visible representation (including tagged items) to its parents.
	local by_id = {}

	for _, item in pairs(state.items) do
		if item.id then
			by_id[item.id] = item
		end
	end

	for _, item in pairs(state.items) do
		local selected = active[item.id]

		if item.note and active["knowledge-note:" .. item.note.id] then
			selected = true
		elseif item.source and active["knowledge-source:" .. item.source.id] then
			selected = true
		end

		local node = selected and item
		local visited = {}
		while node and node.id and not visited[node.id] do
			visited[node.id], active[node.id] = true, true
			node = by_id[node.parent]
		end
	end

	return active
end

-- Context follows the displayed tab, never the sidebar's cursor selection.
function M.refresh_context(state)
	if not (state.buf and api.nvim_buf_is_valid(state.buf)) then
		return
	end

	local sessions = require("aero.session")
	local documents = knowledge_documents(state)
	local panel = require("aero.panel").win()
	local shown = panel and sessions.from_buf(api.nvim_win_get_buf(panel))
	local target = state.target

	if not shown and target and api.nvim_win_is_valid(target) then
		shown = sessions.from_buf(api.nvim_win_get_buf(target))
	end

	local worktree = vim.t.aero_worktree or vim.fn.getcwd(-1, 0)
	local general_directory = require("aero.general").directory()
	local general = worktree == general_directory or shown ~= nil and shown.worktree == general_directory
	local knowledge_directory = require("aero.knowledge.store").directory() .. "/"
	local context_path = shown and shown.worktree or worktree
	local knowledge = type(context_path) == "string" and vim.startswith(context_path, knowledge_directory)
	local scope_kind, scope_id

	if knowledge then
		scope_kind, scope_id = context_path:sub(#knowledge_directory + 1):match("^(%a+)/(%x+)$")
	end

	local collection_id = scope_kind == "collections" and scope_id or nil

	for _, space in ipairs(state.knowledge_catalog and state.knowledge_catalog.spaces or {}) do
		if scope_kind == "spaces" and space.id == scope_id then
			collection_id = space.collection_id
		end
	end

	for _, item in pairs(state.items) do
		if item.space and scope_kind == "spaces" and item.space.id == scope_id then
			collection_id = item.space.collection_id
		end
	end

	local root

	for workspace, cache in pairs(state.worktrees or {}) do
		for _, tree in ipairs(cache.list or {}) do
			if tree.path == worktree then
				root = workspace
				break
			end
		end
	end

	root = root or require("aero.git").cached_main_root(worktree) or worktree
	local in_scene = false

	for _, workspace in ipairs(require("aero.scenes").workspaces()) do
		if workspace.root == root then
			in_scene = true
			break
		end
	end

	api.nvim_buf_clear_namespace(state.buf, context_ns, 0, -1)

	for row, item in pairs(state.items) do
		local active = documents[item.id]
			or item.kind == "worktree" and item.wt.path == worktree
			or item.kind == "workspace" and root ~= nil and item.ws.root == root
			or item.kind == "workspace_group" and in_scene
			or item.kind == "general_group" and general
			or item.kind == "knowledge_group" and knowledge
			or item.kind == "knowledge_collection" and collection_id ~= nil and item.collection.id == collection_id
			or item.kind == "knowledge_space" and scope_kind == "spaces" and item.space.id == scope_id
			or item.kind == "knowledge_section" and item.section == "Sessions" and scope_kind == "spaces" and item.space.id == scope_id
			or item.kind == "session" and shown ~= nil and item.session.key == shown.key
		local waiting = item.kind == "session" and sessions.status(item.session) == "waiting"

		if active or waiting then
			api.nvim_buf_set_extmark(state.buf, context_ns, row - 1, 0, {
				sign_text = active and (waiting and ">?" or "> ") or " ?",
				sign_hl_group = waiting and "AeroSidebarAttention" or "AeroSidebarActive",
				line_hl_group = active and "AeroSidebarActiveLine" or nil,
				priority = 150,
			})
		end
	end
end

function M.render(state, lines, items, marks)
	local buf = state.buf
	local win = state.win and api.nvim_win_is_valid(state.win) and api.nvim_win_get_buf(state.win) == buf and state.win
	local current_line = win and api.nvim_win_get_cursor(win)[1]
	local current_id = current_line and state.items[current_line] and state.items[current_line].id
	state.items = items
	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
	api.nvim_buf_clear_namespace(buf, ns, 0, -1)

	for line, mark in pairs(marks) do
		for _, highlight in ipairs(mark.hls) do
			api.nvim_buf_set_extmark(
				buf,
				ns,
				line - 1,
				highlight[1],
				{ end_col = highlight[2], hl_group = highlight[3] }
			)
		end

		if mark.virt and #mark.virt > 0 then
			api.nvim_buf_set_extmark(buf, ns, line - 1, 0, { virt_text = mark.virt, virt_text_pos = "eol" })
		end
	end

	if win then
		local target = math.min(current_line, #lines)

		for line, item in pairs(items) do
			if current_id and item.id == current_id then
				target = line
				break
			end
		end

		api.nvim_win_set_cursor(win, { target, 0 })
	end

	M.refresh_context(state)
end

return M
