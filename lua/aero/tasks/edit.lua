-- Editable rows are a projection: identity is explicit and never depends on extmarks.
local M = {}

local function identity(entry)
	local ticket = entry.ticket
	return ticket and ticket.valid and ticket.metadata.id or ("invalid:" .. entry.line)
end

function M.title(value)
	return tostring(value or ""):gsub("[%c]", " ")
end

function M.registry(board)
	local registry = {}
	for _, state in ipairs(board.states) do
		for _, entry in ipairs(state.entries) do
			local data = entry.ticket and entry.ticket.metadata
			local id = identity(entry)
			registry[id] = { entry = entry, title = M.title(data and data.title or entry.label) }
		end
	end
	return registry
end

function M.rows(state)
	local rows = {}
	for _, entry in ipairs(state.entries) do
		local data = entry.ticket and entry.ticket.metadata
		table.insert(rows, identity(entry) .. "  " .. M.title(data and data.title or entry.label))
	end
	return #rows > 0 and rows or { "" }
end

function M.parse(states, columns, registry)
	local layout, errors, seen = {}, {}, {}
	for si, state in ipairs(states) do
		local column = columns[si]
		local ids = {}
		layout[si] = { name = state.name, ticket_ids = ids }
		if not column or column.name ~= state.name or not column.lines then
			table.insert(errors, { message = "missing state buffer: " .. state.name, state = si })
		else
			for row, line in ipairs(column.lines) do
				if vim.trim(line) ~= "" then
					local id, label = line:match("^(%S+)  (.*)$")
					local item = id and registry[id]
					local err
					if not item then
						err = "unknown or malformed ticket row"
					elseif seen[id] then
						err = "duplicate ticket: " .. id
					elseif label ~= item.title then
						err = "title changed; use rename or edit ticket metadata"
					end
					if err then
						table.insert(errors, { message = err, state = si, row = row })
					end
					if item then
						seen[id] = true
						table.insert(ids, id)
					end
				end
			end
		end
	end
	for id in pairs(registry) do
		if not seen[id] then
			table.insert(errors, { message = "missing ticket: " .. id })
		end
	end
	return layout, errors
end

return M
