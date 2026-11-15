-- Board state edits share the mutation service's lock-protected reader and commit boundary.
local storage = require("aero.tasks.storage")
local markdown = require("aero.tasks.markdown")
return function(mutable, save)
	local M = {}

	function M.add_state(ws, path, name, position)
		if not markdown.state_name(name) then
			return nil, "invalid state name"
		end

		return storage.with_lock(ws, function()
			local board, err = mutable(ws, path)

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

	function M.rename_state(ws, path, old, name)
		if not markdown.state_name(name) then
			return nil, "invalid state name"
		end

		return storage.with_lock(ws, function()
			local board, err = mutable(ws, path)

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

	function M.reorder_state(ws, path, name, position)
		return storage.with_lock(ws, function()
			local board, err = mutable(ws, path)

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

			for _, item in ipairs(board.states) do
				if item ~= state then
					table.insert(blocks, vim.list_slice(board.lines, item.first, item.last))
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

	function M.remove_state(ws, path, name, destination)
		return storage.with_lock(ws, function()
			local board, err = mutable(ws, path)

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

			for index = #state.entries, 1, -1 do
				table.remove(lines, state.entries[index].line)
			end

			table.remove(lines, state.first)

			-- Remove headings/references only; retain comments and prose.
			for _, item in ipairs(state.entries) do
				local parsed = markdown.parse(storage.text(lines, board.text), "board", board.path)
				lines = markdown.insert(lines, markdown.state(parsed, destination), item.raw)
			end

			return save(board, lines)
		end)
	end

	return M
end
