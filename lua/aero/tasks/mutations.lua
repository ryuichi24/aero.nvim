-- Task mutations retain workspace locks and source/draft revision guards.
-- Query, planning and commit collaborators are separate from board presentation.
local storage = require("aero.tasks.storage")
local markdown = require("aero.tasks.markdown")
local fm = require("aero.tasks.frontmatter")
local M = { directory = storage.directory }

local function now()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end
local function title(value)
	return type(value) == "string" and vim.trim(value) ~= "" and not value:find("%c")
end
local function document(kind, name, id, options, body)
	for field in pairs(options or {}) do
		if type(field) ~= "string" or not field:match("^[%w_-]+$") then
			return nil, "invalid metadata field"
		end
	end
	local data = vim.tbl_extend(
		"force",
		options or {},
		{ aero_type = kind, schema_version = 1, id = id, title = name, created_at = now(), updated_at = now() }
	)
	if kind == "ticket" and data.task_type == nil then
		data.task_type = "general"
	end
	local errors = fm.validate(data, kind)
	if #errors > 0 then
		return nil, table.concat(errors, "; ")
	end
	local lines = { "---" }
	for _, field in ipairs(vim.tbl_keys(data)) do
		table.insert(lines, field .. ": " .. vim.json.encode(data[field]))
	end
	table.insert(lines, "---")
	table.insert(lines, "")
	table.insert(lines, "# " .. name)
	table.insert(lines, "")
	vim.list_extend(lines, body or {})
	return storage.text(lines)
end

function M.read_ticket(board_path, path)
	return require("aero.tasks.query").read_ticket(board_path, path)
end

function M.read_board(ws, path)
	return require("aero.tasks.query").read_board(ws, path)
end

function M.list(ws, include_removed)
	return require("aero.tasks.query").list(ws, include_removed)
end

local function mutable(ws, path)
	local board, err = M.read_board(ws, path)
	if not board then
		return nil, err
	end
	if not board.valid then
		return nil, "fix board diagnostics before changing it: " .. table.concat(board.diagnostics, "; ")
	end
	local ok, buffer_err = storage.unmodified(board.path)
	if not ok then
		return nil, buffer_err
	end
	return board
end

local function save(doc, lines)
	return require("aero.tasks.commit").placements(doc, lines)
end

local function entry(board, path)
	for _, state in ipairs(board.states) do
		for index, item in ipairs(state.entries) do
			if item.path == path then
				return item, state, index
			end
		end
	end
end

function M.revision(text)
	return "sha256:" .. vim.fn.sha256(text)
end

function M.resolve_board(ws, id, boards)
	local matches = {}
	for _, board in ipairs(boards or M.list(ws)) do
		if board.metadata and board.metadata.id == id then
			table.insert(matches, board)
		end
	end
	if #matches > 1 then
		return nil, { code = "AMBIGUOUS_ID", message = "duplicate board ID" }
	end
	if #matches == 0 then
		return nil, { code = "NOT_FOUND", message = "board not found" }
	end
	if not matches[1].valid then
		return nil, { code = "INVALID_DOCUMENT", message = "invalid board", diagnostics = matches[1].diagnostics }
	end
	return matches[1]
end

function M.resolve_ticket(board, id)
	local matches = {}
	for _, state in ipairs(board.states) do
		for _, item in ipairs(state.entries) do
			if item.ticket and item.ticket.metadata and item.ticket.metadata.id == id then
				table.insert(matches, { ticket = item.ticket, state = state.name, error = item.error })
			end
		end
	end
	for _, orphan in ipairs(board.orphans or {}) do
		if orphan.ticket and orphan.ticket.metadata and orphan.ticket.metadata.id == id then
			table.insert(matches, { ticket = orphan.ticket, orphan = true })
		end
	end
	if #matches > 1 then
		return nil, { code = "AMBIGUOUS_ID", message = "duplicate ticket ID" }
	end
	if #matches == 0 or matches[1].orphan then
		return nil, { code = "NOT_FOUND", message = "referenced ticket not found" }
	end
	if matches[1].error or not matches[1].ticket.valid then
		return nil, { code = "INVALID_DOCUMENT", message = matches[1].error or "invalid ticket" }
	end
	return matches[1].ticket, matches[1].state
end

-- Optional agent guard executes inside the existing lock, before any mutation.
local function guarded(options, board, ticket_path, document)
	if options and options.guard then
		return options.guard(board, ticket_path, document)
	end
	return true
end

function M.create_board(ws, name, options)
	if not title(name) then
		return nil, "board title must be nonempty and single-line"
	end
	local states = require("aero.config").options.tasks.states
	if type(states) ~= "table" or not vim.islist(states) or #states == 0 then
		return nil, "tasks.states must be a nonempty list"
	end
	local seen, body = {}, {}
	for _, state in ipairs(states) do
		if not markdown.state_name(state) or seen[state] then
			return nil, "invalid or duplicate default state"
		end
		seen[state] = true
		vim.list_extend(body, { "## " .. state, "" })
	end
	return storage.with_lock(ws, function()
		local id = storage.id("board")
		local text, err = document("board", name, id, options, body)
		if not text then
			return nil, err
		end
		local folder =
			vim.fs.joinpath(assert(storage.directory(ws)), name:gsub("[^%w._-]", "-"):sub(1, 48) .. "-" .. id)
		local made, mkdir_err = vim.uv.fs_mkdir(folder, 493)
		if not made then
			return nil, mkdir_err
		end
		local ok, tickets_err = vim.uv.fs_mkdir(vim.fs.joinpath(folder, "tickets"), 493)
		if not ok then
			return nil, tickets_err
		end
		local path = vim.fs.joinpath(folder, "board.md")
		ok, err = storage.create(path, text)
		if not ok then
			return nil, err
		end
		return M.read_board(ws, path)
	end)
end

function M.create_ticket(ws, board_path, state_name, name, options, body)
	if not title(name) then
		return nil, "ticket title must be nonempty and single-line"
	end
	return storage.with_lock(ws, function()
		local board, err = (options and options.guard and M.read_board or mutable)(ws, board_path)
		if not board then
			return nil, err
		end
		local allowed, guard_err = guarded(options, board)
		if not allowed then
			return nil, guard_err
		end
		local state = markdown.state(board, state_name or board.states[1].name)
		if not state then
			return nil, "unknown state"
		end
		local id = storage.id("task")
		local path, path_err = storage.ticket_path(board.path, "tickets/" .. id .. ".md")
		if not path then
			return nil, path_err
		end
		local metadata = vim.tbl_extend("force", options or {}, { state = state.name })
		metadata.guard = nil
		local text, doc_err =
			document("ticket", name, id, metadata, body or { "## Description", "", "## Acceptance criteria", "" })
		if not text then
			return nil, doc_err
		end
		vim.fn.mkdir(vim.fs.dirname(path), "p")
		local ok, create_err = storage.create(path, text)
		if not ok then
			return nil, create_err
		end
		local ticket = markdown.parse(text, "ticket", path)
		ok, err = save(board, markdown.insert(board.lines, state, markdown.entry(ticket)))
		if not ok then
			return nil, tostring(err) .. "; recover the orphan ticket at " .. path
		end
		return ticket
	end)
end

function M.move_ticket(ws, board_path, ticket_path, state_name, position, options)
	return storage.with_lock(ws, function()
		local board, err = (options and options.guard and M.read_board or mutable)(ws, board_path)
		if not board then
			return nil, err
		end
		local item, current_state = entry(board, ticket_path)
		local allowed, guard_err = guarded(options, board, ticket_path)
		if not allowed then
			return nil, guard_err
		end
		local state = markdown.state(board, state_name or current_state and current_state.name)
		if not state then
			return nil, "unknown state"
		end
		if item and current_state.name == state.name and position == nil then
			if item.ticket and item.ticket.valid and item.ticket.metadata.state ~= state.name then
				local ticket = item.ticket
				local lines = fm.edit(ticket.lines, ticket.frontmatter, { state = state.name, updated_at = now() })
				return storage.write(ticket.path, ticket.text, storage.text(lines, ticket.text))
			end
			return true
		end
		local raw
		if item then
			if item.error then
				return nil, item.error
			end
			raw = item.raw
		else
			local ticket, ticket_err = M.read_ticket(board.path, ticket_path)
			if not ticket or not ticket.valid then
				return nil, ticket_err or "invalid orphan metadata"
			end
			raw = markdown.entry(ticket)
		end
		local lines = vim.deepcopy(board.lines)
		if item then
			table.remove(lines, item.line)
		end
		local reparsed = markdown.parse(storage.text(lines, board.text), "board", board.path)
		state = markdown.state(reparsed, state.name)
		if
			position
			and (type(position) ~= "number" or position % 1 ~= 0 or position < 1 or position > #state.entries + 1)
		then
			return nil, "invalid ticket position"
		end
		return save(board, markdown.insert(lines, state, raw, position))
	end)
end

function M.reorder_ticket(ws, board_path, ticket_path, position)
	return M.move_ticket(ws, board_path, ticket_path, nil, position)
end

function M.list_removed(ws)
	local removed = {}
	local boards, diagnostics = M.list(ws, true)
	for _, board in ipairs(boards) do
		for _, orphan in ipairs(board.orphans) do
			local ticket = orphan.ticket
			table.insert(removed, {
				board_path = board.path,
				board_id = board.metadata and board.metadata.id,
				board_title = board.metadata and board.metadata.title or board.path,
				path = orphan.path,
				ticket = ticket,
				title = ticket
						and ticket.metadata
						and type(ticket.metadata.title) == "string"
						and ticket.metadata.title
					or vim.fs.basename(orphan.path),
				error = orphan.error or ticket and not ticket.valid and table.concat(ticket.diagnostics, "; "),
			})
		end
	end
	table.sort(removed, function(a, b)
		return a.title == b.title and a.path < b.path or a.title < b.title
	end)
	return removed, diagnostics
end

-- Validate the complete deletion draft before unlinking any retained files.
function M.delete_removed(ws, items)
	return storage.with_lock(ws, function()
		local checked, seen = {}, {}
		for _, item in ipairs(items) do
			local board, err = M.read_board(ws, item.board_path)
			if not board then
				return nil, err
			end
			if board.metadata.id ~= item.board_id then
				return nil, "board identity changed; reload the list"
			end
			local status = require("aero.tasks.view").status(board.path)
			if status.dirty or status.missing_column then
				return nil, "save or discard board edits before deleting removed tickets"
			end
			local ok, draft_err = storage.unmodified(board.path)
			if not ok then
				return nil, draft_err
			end
			local ticket, ticket_err = M.read_ticket(board.path, item.path)
			if not ticket then
				return nil, ticket_err
			end
			if seen[ticket.path] then
				return nil, "duplicate removed ticket"
			end
			seen[ticket.path] = true
			if entry(board, ticket.path) then
				return nil, "ticket is no longer removed; reload the list"
			end
			if ticket.text ~= item.text then
				return nil, "removed ticket changed; reload the list"
			end
			ok, draft_err = storage.unmodified(ticket.path)
			if not ok then
				return nil, draft_err
			end
			table.insert(checked, item)
		end
		local deleted = {}
		for _, item in ipairs(checked) do
			-- Closing a deleted file's buffer can run user autocmds between items.
			local board = M.read_board(ws, item.board_path)
			if not board or board.metadata.id ~= item.board_id or entry(board, item.path) then
				return nil, "ticket is no longer removed; reload the list", deleted
			end
			if storage.read(item.path) ~= item.text then
				return nil, "removed ticket changed; reload the list", deleted
			end
			local clean, draft_err = storage.unmodified(item.path)
			if not clean then
				return nil, draft_err, deleted
			end
			local ok, err = vim.uv.fs_unlink(item.path)
			if not ok then
				return nil, err, deleted
			end
			table.insert(deleted, item)
			local buf = vim.fn.bufnr(item.path)
			if buf ~= -1 then
				pcall(vim.api.nvim_buf_delete, buf, { force = true })
			end
		end
		return deleted
	end)
end

-- Restore a removed ticket, transferring its file only when the owning board changes.
function M.recover_ticket(ws, source_path, ticket_path, target_path, state_name, options)
	return storage.with_lock(ws, function()
		local source, err = mutable(ws, source_path)
		if not source then
			return nil, err
		end
		local target
		if source.path == require("aero.storage").canonical(target_path) then
			target = source
		else
			target, err = mutable(ws, target_path)
		end
		if not target then
			return nil, err
		end
		if options and options.guard then
			local allowed, guard_err = options.guard(source, target)
			if not allowed then
				return nil, guard_err
			end
		end
		local ticket, ticket_err = M.read_ticket(source.path, ticket_path)
		if not ticket or not ticket.valid then
			return nil, ticket_err or "invalid removed ticket"
		end
		if options and options.expected_ticket_id and ticket.metadata.id ~= options.expected_ticket_id then
			return nil, "removed ticket identity changed; reload the list"
		end
		if entry(source, ticket.path) then
			return nil, "ticket is no longer removed; reload the list"
		end
		for _, s in ipairs(source.states) do
			for _, item in ipairs(s.entries) do
				if item.ticket and item.ticket.metadata and item.ticket.metadata.id == ticket.metadata.id then
					return nil, "removed ticket identity conflicts with a referenced ticket"
				end
			end
		end
		local found = 0
		for _, orphan in ipairs(source.orphans) do
			if orphan.ticket and orphan.ticket.metadata and orphan.ticket.metadata.id == ticket.metadata.id then
				found = found + 1
			end
		end
		if found ~= 1 then
			return nil, "removed ticket identity is missing or ambiguous"
		end
		local state = markdown.state(target, state_name)
		if not state then
			return nil, "unknown recovery state"
		end
		local destination = ticket.path
		if target ~= source then
			for _, s in ipairs(target.states) do
				for _, item in ipairs(s.entries) do
					if item.ticket and item.ticket.metadata and item.ticket.metadata.id == ticket.metadata.id then
						return nil, "destination board already contains this ticket ID"
					end
				end
			end
			for _, orphan in ipairs(target.orphans) do
				if orphan.ticket and orphan.ticket.metadata and orphan.ticket.metadata.id == ticket.metadata.id then
					return nil, "destination board already has a removed ticket with this ID"
				end
			end
			local path_err
			destination, path_err = storage.ticket_path(target.path, "tickets/" .. vim.fs.basename(ticket.path))
			if not destination then
				return nil, path_err
			end
		end
		local ok, buffer_err = storage.unmodified(ticket.path)
		if not ok then
			return nil, buffer_err
		end
		local source_buf, target_buf = vim.fn.bufnr(ticket.path), vim.fn.bufnr(destination)
		if destination ~= ticket.path and source_buf > 0 and target_buf > 0 then
			return nil, "destination ticket path already has an editor buffer; close it before transferring"
		end
		if destination ~= ticket.path then
			vim.fn.mkdir(vim.fs.dirname(destination), "p")
			ok, err = storage.create(destination, ticket.text)
			if not ok then
				return nil, "could not create recovery copy at " .. destination .. ": " .. tostring(err)
			end
			local stat = vim.uv.fs_stat(ticket.path)
			if stat then
				ok, err = vim.uv.fs_chmod(destination, stat.mode % 512)
				if not ok then
					local cleaned = storage.read(target.path) == target.text
						and storage.read(destination) == ticket.text
						and storage.unmodified(destination)
						and vim.uv.fs_unlink(destination)
					return nil,
						"could not preserve ticket permissions: "
							.. tostring(err)
							.. (not cleaned and "; retained recovery copy: " .. destination or "")
				end
			end
		end
		local placed = { path = destination, metadata = ticket.metadata }
		ok, err = save(target, markdown.insert(target.lines, state, markdown.entry(placed)))
		if not ok then
			-- Only remove an untouched copy when no external board edit could reference it.
			if destination ~= ticket.path then
				if
					storage.read(target.path) == target.text
					and storage.read(destination) == ticket.text
					and storage.unmodified(destination)
				then
					local deleted = vim.uv.fs_unlink(destination)
					if not deleted then
						err = tostring(err) .. "; retained recovery copy: " .. destination
					end
				else
					err = tostring(err) .. "; retained recovery copy: " .. destination
				end
			end
			return nil, err
		end
		local warning
		if destination ~= ticket.path then
			if
				storage.read(source.path) ~= source.text
				or storage.read(ticket.path) ~= ticket.text
				or not storage.unmodified(ticket.path)
			then
				warning = "recovered ticket, but the changed source was retained at " .. ticket.path
			else
				local deleted, unlink_err = vim.uv.fs_unlink(ticket.path)
				if not deleted then
					warning = "recovered ticket, but retained its old file at "
						.. ticket.path
						.. ": "
						.. tostring(unlink_err)
				elseif source_buf > 0 and vim.api.nvim_buf_is_valid(source_buf) then
					local renamed, rename_err = pcall(vim.api.nvim_buf_set_name, source_buf, destination)
					if not renamed then
						warning = "ticket transferred; editor buffer rename failed: " .. tostring(rename_err)
					else
						local refreshed, refresh_err = pcall(storage.refresh, destination)
						if not refreshed then
							warning = "ticket transferred; editor buffer refresh failed: " .. tostring(refresh_err)
						end
					end
				end
			end
		end
		return { path = destination, board_path = target.path, warning = warning }
	end)
end

--- Commit an entire editable board in one locked write, never a sequence of moves.
function M.apply_layout(ws, board_path, request)
	return storage.with_lock(ws, function()
		local board, err = mutable(ws, board_path)
		if not board then
			return nil, err
		end
		local plan, plan_err = require("aero.tasks.layout_plan").prepare(board, request)
		if not plan then
			return nil, plan_err
		end
		local states, registry, pending = plan.states, plan.registry, plan.pending
		if not plan.changed then
			return true, nil, board.text
		end
		local created, files = {}, {}
		local function rollback(message)
			local kept = {}
			for path, text in pairs(files) do
				-- Never remove a changed file, or a ticket potentially linked by an external edit.
				if
					storage.read(board.path) == board.text
					and storage.read(path) == text
					and storage.unmodified(path)
				then
					if not vim.uv.fs_unlink(path) then
						table.insert(kept, path)
					end
				else
					table.insert(kept, path)
				end
			end
			return nil,
				tostring(message) .. (#kept > 0 and "; recover created tickets: " .. table.concat(kept, ", ") or "")
		end
		for _, new in ipairs(pending) do
			local id = storage.id("task")
			local path, path_err = storage.ticket_path(board.path, "tickets/" .. id .. ".md")
			if not path then
				return rollback(path_err)
			end
			local text, doc_err = document(
				"ticket",
				new.title,
				id,
				{ state = new.state },
				{ "## Description", "", "## Acceptance criteria", "" }
			)
			if not text then
				return rollback(doc_err)
			end
			local ticket = markdown.parse(text, "ticket", path)
			if not ticket.valid then
				return rollback(table.concat(ticket.diagnostics, "; "))
			end
			vim.fn.mkdir(vim.fs.dirname(path), "p")
			local ok, create_err = storage.create(path, text)
			if not ok then
				return rollback(create_err)
			end
			files[path] = text
			registry[new.key] = { raw = markdown.entry(ticket) }
			created[new.key] = ticket
		end
		local ran, ok, write_err = pcall(save, board, markdown.placements(board, states, registry))
		if not ran or not ok then
			return rollback(ran and write_err or ok)
		end
		return true, nil, storage.read(board.path), created
	end)
end

function M.remove_ticket(ws, board_path, ticket_path, permanent)
	return storage.with_lock(ws, function()
		local board, err = mutable(ws, board_path)
		if not board then
			return nil, err
		end
		local safe, path_err = storage.ticket_path(board.path, "tickets/" .. vim.fs.basename(ticket_path))
		if not safe or safe ~= require("aero.storage").canonical(ticket_path) then
			return nil, path_err or "ticket belongs to another board"
		end
		local item = entry(board, safe)
		local original = permanent and storage.read(safe)
		local ok, unsaved_err = storage.unmodified(safe)
		if permanent and not ok then
			return nil, unsaved_err
		end
		if item then
			local lines = vim.deepcopy(board.lines)
			table.remove(lines, item.line)
			ok, err = save(board, lines)
			if not ok then
				return nil, err
			end
		end
		if permanent then
			if storage.read(safe) ~= original then
				return nil, "ticket changed before deletion; its file was kept as an orphan"
			end
			ok, unsaved_err = storage.unmodified(safe)
			if not ok then
				return nil, unsaved_err
			end
			return vim.uv.fs_unlink(safe)
		end
		return true
	end)
end

function M.update_metadata(ws, board_path, ticket_path, changes, options)
	return storage.with_lock(ws, function()
		local reader = options and options.guard and ticket_path and not changes.title and M.read_board or mutable
		local board, err = reader(ws, board_path)
		if not board then
			return nil, err
		end
		local doc = board
		if ticket_path then
			doc, err = M.read_ticket(board.path, ticket_path)
			if not doc then
				return nil, err
			end
		end
		if not doc.valid then
			return nil, "fix document diagnostics before editing metadata"
		end
		local allowed, guard_err = guarded(options, board, ticket_path, doc)
		if not allowed then
			return nil, guard_err
		end
		for _, field in ipairs({ "id", "schema_version", "aero_type", "created_at" }) do
			if changes[field] ~= nil then
				return nil, "identity field cannot be edited: " .. field
			end
		end
		if ticket_path and changes.state ~= nil then
			return nil, "ticket state is managed by board placement; move the ticket instead"
		end
		local updated = vim.tbl_extend("force", doc.metadata, changes, { updated_at = now() })
		local errors = fm.validate(updated, ticket_path and "ticket" or "board")
		if #errors > 0 then
			return nil, table.concat(errors, "; ")
		end
		local edits = vim.tbl_extend("force", changes, { updated_at = updated.updated_at })
		local lines = doc.lines
		if changes.title then
			lines = markdown.title(lines, doc.metadata.title, changes.title, doc.frontmatter.finish)
		end
		lines = fm.edit(lines, doc.frontmatter, edits)
		local ok, write_err = storage.write(doc.path, doc.text, storage.text(lines, doc.text))
		if not ok then
			return nil, write_err
		end
		if ticket_path and changes.title then
			local item = entry(board, doc.path)
			if item then
				local board_lines = vim.deepcopy(board.lines)
				local comment = item.raw:match("%s+(<!%-%-.*%-%->)%s*$")
				board_lines[item.line] = markdown.entry({ path = doc.path, metadata = updated })
					.. (comment and " " .. comment or "")
				ok, write_err = save(board, board_lines)
				if not ok then
					return nil, "metadata saved but board label update failed: " .. tostring(write_err)
				end
			end
		end
		return true
	end)
end

function M.update_body(ws, board_path, ticket_path, body, options)
	if type(body) ~= "string" or body:find("\0", 1, true) then
		return nil, { code = "INVALID_ARGUMENT", message = "body must be Markdown text without NUL bytes" }
	end
	return storage.with_lock(ws, function()
		local board, err = M.read_board(ws, board_path)
		if not board or not board.valid then
			return nil, err or { code = "INVALID_DOCUMENT", message = "invalid board" }
		end
		local ticket, ticket_err = M.read_ticket(board.path, ticket_path)
		if not ticket or not ticket.valid then
			return nil, ticket_err or { code = "INVALID_DOCUMENT", message = "invalid ticket" }
		end
		local allowed, guard_err = guarded(options, board, ticket_path, ticket)
		if not allowed then
			return nil, guard_err
		end
		local lines = vim.list_slice(ticket.lines, 1, ticket.frontmatter.finish)
		vim.list_extend(lines, storage.lines(body))
		lines = fm.edit(lines, ticket.frontmatter, { updated_at = now() })
		return storage.write(ticket.path, ticket.text, storage.text(lines, ticket.text))
	end)
end

function M.rename_board(ws, path, name)
	return M.update_metadata(ws, path, nil, { title = name })
end
function M.rename_ticket(ws, path, ticket, name)
	return M.update_metadata(ws, path, ticket, { title = name })
end
function M.archive_board(ws, path, archived)
	return M.update_metadata(ws, path, nil, { archived = archived ~= false })
end

function M.add_state(ws, board_path, name, position)
	if not markdown.state_name(name) then
		return nil, "invalid state name"
	end
	return storage.with_lock(ws, function()
		local board, err = mutable(ws, board_path)
		if not board then
			return nil, err
		end
		if markdown.state(board, name) then
			return nil, "state already exists"
		end
		position = position or #board.states + 1
		if position % 1 ~= 0 or position < 1 or position > #board.states + 1 then
			return nil, "invalid state position"
		end
		local at = board.states[position] and board.states[position].first or #board.lines + 1
		local lines = vim.deepcopy(board.lines)
		table.insert(lines, at, "## " .. name)
		table.insert(lines, at + 1, "")
		return save(board, lines)
	end)
end

function M.rename_state(ws, board_path, old, name)
	if not markdown.state_name(name) then
		return nil, "invalid state name"
	end
	return storage.with_lock(ws, function()
		local board, err = mutable(ws, board_path)
		if not board then
			return nil, err
		end
		local state = markdown.state(board, old)
		if not state then
			return nil, "unknown state"
		end
		if name ~= old and markdown.state(board, name) then
			return nil, "state already exists"
		end
		local lines = vim.deepcopy(board.lines)
		lines[state.first] = "## " .. name
		return save(board, lines)
	end)
end

function M.reorder_state(ws, board_path, name, position)
	return storage.with_lock(ws, function()
		local board, err = mutable(ws, board_path)
		if not board then
			return nil, err
		end
		local state = markdown.state(board, name)
		if not state then
			return nil, "unknown state"
		end
		if position % 1 ~= 0 or position < 1 or position > #board.states then
			return nil, "invalid state position"
		end
		local blocks = {}
		for _, s in ipairs(board.states) do
			if s ~= state then
				table.insert(blocks, vim.list_slice(board.lines, s.first, s.last))
			end
		end
		table.insert(blocks, position, vim.list_slice(board.lines, state.first, state.last))
		local lines = vim.list_slice(board.lines, 1, board.states[1].first - 1)
		for _, block in ipairs(blocks) do
			vim.list_extend(lines, block)
		end
		return save(board, lines)
	end)
end

function M.remove_state(ws, board_path, name, destination)
	return storage.with_lock(ws, function()
		local board, err = mutable(ws, board_path)
		if not board then
			return nil, err
		end
		if #board.states == 1 then
			return nil, "a board must retain at least one state"
		end
		local state = markdown.state(board, name)
		if not state then
			return nil, "unknown state"
		end
		local target = destination and markdown.state(board, destination)
		if #state.entries > 0 and (not target or target == state) then
			return nil, "choose another state for the tickets"
		end
		local lines = vim.deepcopy(board.lines)
		for i = #state.entries, 1, -1 do
			table.remove(lines, state.entries[i].line)
		end
		table.remove(lines, state.first)
		-- Only remove the heading and references. Notes and comments are retained.
		for _, item in ipairs(state.entries) do
			local parsed = markdown.parse(storage.text(lines, board.text), "board", board.path)
			lines = markdown.insert(lines, markdown.state(parsed, destination), item.raw)
		end
		return save(board, lines)
	end)
end

function M.delete_board(ws, path)
	return storage.with_lock(ws, function()
		local board, err = M.read_board(ws, path)
		if not board then
			return nil, err
		end
		local folder = vim.fs.dirname(board.path)
		local snapshots = {}
		local function check(directory)
			local scan = vim.uv.fs_scandir(directory)
			if not scan then
				return nil, "cannot inspect board folder"
			end
			while true do
				local name, kind = vim.uv.fs_scandir_next(scan)
				if not name then
					break
				end
				local candidate = vim.fs.joinpath(directory, name)
				if kind == "link" then
					return nil, "remove symlink aliases before deleting the board"
				end
				local ok, check_err
				if kind == "directory" then
					ok, check_err = check(candidate)
				else
					ok, check_err = storage.unmodified(candidate)
					snapshots[candidate] = storage.read(candidate)
				end
				if not ok then
					return nil, check_err
				end
			end
			return true
		end
		local ok, check_err = check(folder)
		if not ok then
			return nil, check_err
		end
		for candidate, original in pairs(snapshots) do
			if storage.read(candidate) ~= original then
				return nil, "board folder changed externally; refresh"
			end
		end
		if storage.read(board.path) ~= board.text then
			return nil, "board changed externally; refresh"
		end
		-- Retained tickets belong to the workspace even after their source board
		-- disappears. Keep a private recovery manifest, excluded from board pickers.
		if #board.orphans > 0 then
			local retained = vim.fs.joinpath(assert(storage.directory(ws)), ".removed-" .. storage.id("archive"))
			vim.fn.mkdir(vim.fs.joinpath(retained, "tickets"), "p")
			local states = {}
			for _, state in ipairs(board.states) do
				table.insert(states, { name = state.name, ticket_ids = {} })
			end
			local manifest = vim.fs.joinpath(retained, "board.md")
			local created, create_err =
				storage.create(manifest, storage.text(markdown.placements(board, states, {}), board.text))
			if not created then
				return nil, create_err
			end
			for _, orphan in ipairs(board.orphans) do
				local destination = vim.fs.joinpath(retained, "tickets", vim.fs.basename(orphan.path))
				local moved, move_err = vim.uv.fs_rename(orphan.path, destination)
				if not moved then
					return nil, "could not retain removed ticket: " .. tostring(move_err)
				end
				local buf = vim.fn.bufnr(orphan.path)
				if buf > 0 then
					pcall(vim.api.nvim_buf_set_name, buf, destination)
				end
			end
		end
		if vim.fn.delete(folder, "rf") ~= 0 then
			return nil, "could not delete board folder"
		end
		return true
	end)
end

return M
