-- Validate and reconcile a board-editor layout without writing files.
-- The mutation service calls this while holding the existing workspace lock.
local markdown = require("aero.tasks.markdown")
local documents = require("aero.tasks.documents")
local edit = require("aero.tasks.edit")
local M = {}

function M.prepare(board, request)
	if type(request) ~= "table" or request.expected_text ~= board.text then
		return nil, "board changed externally; draft kept (reload or compare source)"
	end

	local states = request.states

	if type(states) ~= "table" or #states ~= #board.states then
		return nil, "state layout changed"
	end

	local registry, seen, changed = {}, {}, false
	local new_tickets, pending = request.new_tickets or {}, {}
	local removed, restored = request.removed_tickets or {}, request.restored_tickets or {}

	if type(removed) ~= "table" or type(restored) ~= "table" then
		return nil, "invalid removed or restored tickets"
	end

	if type(new_tickets) ~= "table" then
		return nil, "invalid new tickets"
	end

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

	local function identity_matches(id, item)
		if request.paths and request.paths[id] ~= item.path then
			return nil, "ticket identity/path changed; reload draft"
		end

		if request.titles and request.titles[id] ~= edit.title(item.ticket.metadata.title) then
			return nil, "ticket title changed externally; reload draft"
		end

		return true
	end

	for id, remove in pairs(removed) do
		if remove ~= true or not registry[id] then
			return nil, "unknown removed ticket identity: " .. tostring(id)
		end

		local ok, err = identity_matches(id, registry[id])

		if not ok then
			return nil, err
		end
	end

	for id, restore in pairs(restored) do
		if restore ~= true or registry[id] then
			return nil, "invalid restored ticket identity: " .. tostring(id)
		end

		local found

		for _, orphan in ipairs(board.orphans or {}) do
			if orphan.ticket and orphan.ticket.metadata and orphan.ticket.metadata.id == id then
				if found then
					return nil, "duplicate restored ticket identity: " .. tostring(id)
				end

				found = orphan
			end
		end

		if not found or found.error or not found.ticket.valid then
			return nil, "missing or invalid restored ticket: " .. tostring(id)
		end

		registry[id] = { path = found.path, ticket = found.ticket, raw = markdown.entry(found.ticket) }
	end

	for state_index, state in ipairs(states) do
		local original = board.states[state_index]

		if state.name ~= original.name or type(state.ticket_ids) ~= "table" or not vim.islist(state.ticket_ids) then
			return nil, "invalid state layout"
		end

		changed = changed or #state.ticket_ids ~= #original.entries

		for ticket_index, id in ipairs(state.ticket_ids) do
			if seen[id] then
				return nil, "unknown or duplicate ticket identity: " .. tostring(id)
			end

			seen[id] = true

			if not registry[id] then
				local new = new_tickets[id]

				if
					type(id) ~= "string"
					or not id:match("^new:%d+:%d+$")
					or type(new) ~= "table"
					or not documents.title(new.title)
				then
					return nil, "unknown identity or invalid new ticket title: " .. tostring(id)
				end

				table.insert(pending, { key = id, title = new.title, state = state.name })
				changed = true
			else
				changed = changed
					or not original.entries[ticket_index]
					or original.entries[ticket_index].ticket.metadata.id ~= id
				local ok, err = identity_matches(id, registry[id])

				if not ok then
					return nil, err
				end
			end
		end
	end

	for id in pairs(registry) do
		if removed[id] and seen[id] then
			return nil, "removed ticket is still present: " .. id
		end

		if restored[id] and not seen[id] then
			return nil, "unreferenced restored ticket: " .. id
		end

		if not seen[id] and not removed[id] then
			return nil, "missing ticket: " .. id
		end
	end

	for key in pairs(new_tickets) do
		if not seen[key] or registry[key] then
			return nil, "unreferenced or conflicting new ticket"
		end
	end

	return { states = states, registry = registry, pending = pending, changed = changed }
end

return M
