-- UI-independent workspace task service. Markdown is the only task registry.
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
	local safe, err = storage.ticket_path(board_path, "tickets/" .. vim.fs.basename(path))
	if not safe or safe ~= require("aero.storage").canonical(path) then
		return nil, err or "ticket belongs to another board"
	end
	local text, read_err = storage.read(safe)
	if not text then
		return nil, "missing ticket: " .. (read_err or safe)
	end
	return markdown.parse(text, "ticket", safe)
end

function M.read_board(ws, path)
	local safe, err = storage.board_path(ws, path)
	if not safe then
		return nil, err
	end
	local text, read_err = storage.read(safe)
	if not text then
		return nil, read_err
	end
	local board = markdown.parse(text, "board", safe)
	board.ws, board.orphans, board.count = ws, {}, 0
	local referenced, ids = {}, {}
	for _, state in ipairs(board.states) do
		for _, entry in ipairs(state.entries) do
			board.count = board.count + 1
			if entry.path and not entry.error then
				referenced[entry.path] = true
				local ticket, ticket_err = M.read_ticket(safe, entry.path)
				entry.ticket = ticket
				entry.error = ticket_err
				if ticket then
					entry.error = #ticket.diagnostics > 0 and table.concat(ticket.diagnostics, "; ") or nil
					local id = ticket.metadata and ticket.metadata.id
					if id and ids[id] then
						entry.error = "duplicate ticket id: " .. id
					end
					if id then
						ids[id] = true
					end
				end
				if entry.error then
					table.insert(board.diagnostics, entry.error)
				end
			end
		end
	end
	local directory = vim.fs.joinpath(vim.fs.dirname(safe), "tickets")
	local stat = vim.uv.fs_lstat(directory)
	if stat and stat.type ~= "directory" then
		table.insert(board.diagnostics, "tickets directory must not be a symlink")
	else
		for _, candidate in ipairs(storage.list(directory, "file")) do
			if candidate:match("%.md$") and not referenced[candidate] then
				local ticket, ticket_err = M.read_ticket(safe, candidate)
				table.insert(board.orphans, { path = candidate, ticket = ticket, error = ticket_err })
				table.insert(board.diagnostics, "orphan ticket: " .. vim.fs.basename(candidate))
			end
		end
	end
	return board
end

function M.list(ws)
	local directory, err = storage.directory(ws)
	if not directory then
		return {}, { err }
	end
	local folders, list_err = storage.list(directory, "directory")
	local boards, diagnostics, ids = {}, {}, {}
	if list_err then
		table.insert(diagnostics, list_err)
	end
	for _, folder in ipairs(folders) do
		local path = vim.fs.joinpath(folder, "board.md")
		if vim.uv.fs_lstat(path) then
			local board, read_err = M.read_board(ws, path)
			if board then
				table.insert(boards, board)
				local id = board.metadata and board.metadata.id
				if id and ids[id] then
					board.valid = false
					table.insert(board.diagnostics, "duplicate board id: " .. id)
				end
				if id then
					ids[id] = true
				end
			else
				table.insert(diagnostics, read_err)
			end
		end
	end
	table.sort(boards, function(a, b)
		return tostring(a.metadata and a.metadata.title or a.path) < tostring(b.metadata and b.metadata.title or b.path)
	end)
	return boards, diagnostics
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
	local changed = fm.edit(lines, doc.frontmatter, { updated_at = now() })
	return storage.write(doc.path, doc.text, storage.text(changed, doc.text))
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
		local board, err = mutable(ws, board_path)
		if not board then
			return nil, err
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
		local text, doc_err =
			document("ticket", name, id, options, body or { "## Description", "", "## Acceptance criteria", "" })
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

function M.move_ticket(ws, board_path, ticket_path, state_name, position)
	return storage.with_lock(ws, function()
		local board, err = mutable(ws, board_path)
		if not board then
			return nil, err
		end
		local item, current_state = entry(board, ticket_path)
		local state = markdown.state(board, state_name or current_state and current_state.name)
		if not state then
			return nil, "unknown state"
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

--- Commit an entire editable board in one locked write, never a sequence of moves.
function M.apply_layout(ws, board_path, request)
	return storage.with_lock(ws, function()
		local board, err = mutable(ws, board_path)
		if not board then
			return nil, err
		end
		if type(request) ~= "table" or request.expected_text ~= board.text then
			return nil, "board changed externally; draft kept (reload or compare source)"
		end
		local states = request.states
		if type(states) ~= "table" or #states ~= #board.states then
			return nil, "state layout changed"
		end
		local registry, seen, changed = {}, {}, false
		for _, state in ipairs(board.states) do
			for _, item in ipairs(state.entries) do
				if item.error or not item.ticket or not item.ticket.valid then
					return nil, item.error or "invalid ticket"
				end
				local id = item.ticket.metadata.id
				if registry[id] then
					return nil, "duplicate ticket identity"
				end
				registry[id] = item
			end
		end
		for si, state in ipairs(states) do
			local original = board.states[si]
			if state.name ~= original.name or type(state.ticket_ids) ~= "table" or not vim.islist(state.ticket_ids) then
				return nil, "invalid state layout"
			end
			changed = changed or #state.ticket_ids ~= #original.entries
			for ti, id in ipairs(state.ticket_ids) do
				if not registry[id] or seen[id] then
					return nil, "unknown or duplicate ticket identity: " .. tostring(id)
				end
				seen[id] = true
				changed = changed or not original.entries[ti] or original.entries[ti].ticket.metadata.id ~= id
				if request.paths and request.paths[id] ~= registry[id].path then
					return nil, "ticket identity/path changed; reload draft"
				end
				if
					request.titles
					and request.titles[id] ~= require("aero.tasks.edit").title(registry[id].ticket.metadata.title)
				then
					return nil, "ticket title changed externally; reload draft"
				end
			end
		end
		for id in pairs(registry) do
			if not seen[id] then
				return nil, "missing ticket: " .. id
			end
		end
		if not changed then
			return true, nil, board.text
		end
		local ok, write_err = save(board, markdown.placements(board, states, registry))
		if not ok then
			return nil, write_err
		end
		return true, nil, storage.read(board.path)
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

function M.update_metadata(ws, board_path, ticket_path, changes)
	return storage.with_lock(ws, function()
		local board, err = mutable(ws, board_path)
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
		for _, field in ipairs({ "id", "schema_version", "aero_type", "created_at" }) do
			if changes[field] ~= nil then
				return nil, "identity field cannot be edited: " .. field
			end
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
		if vim.fn.delete(folder, "rf") ~= 0 then
			return nil, "could not delete board folder"
		end
		return true
	end)
end

return M
