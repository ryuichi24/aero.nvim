-- Read-only task discovery and document projection. Reads never create storage.
local storage = require("aero.tasks.storage")
local markdown = require("aero.tasks.markdown")
local M = {}

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
				entry.ticket, entry.error = ticket, ticket_err

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

				if ticket_err or ticket and not ticket.valid then
					table.insert(board.diagnostics, "invalid removed ticket: " .. vim.fs.basename(candidate))
				end
			end
		end
	end

	return board
end

function M.list(ws, include_removed)
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

		if vim.uv.fs_lstat(path) and (include_removed or not vim.fs.basename(folder):match("^%.removed%-")) then
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

return M
