-- Board editor save transaction: snapshot buffers, validate, commit, then reconcile native undo state.
local api = vim.api
local tasks = require("aero.tasks")
local storage = require("aero.tasks.storage")
local edit = require("aero.tasks.edit")
local M = {}

function M.save(view, effects)
	if view.saving then
		return
	end

	local columns, ticks, paths, titles = {}, {}, {}, {}

	for index, column in ipairs(view.columns) do
		if api.nvim_buf_is_valid(column.buf) then
			columns[index] = { name = column.name, lines = api.nvim_buf_get_lines(column.buf, 0, -1, false) }
			ticks[column.buf] = api.nvim_buf_get_changedtick(column.buf)
			vim.diagnostic.reset(effects.diagnostics, column.buf)
		else
			columns[index] = { name = column.name }
		end
	end

	local states, errors, new_tickets, removed, restored = edit.parse(view.board.states, columns, view.registry)

	if #errors > 0 then
		local by_buffer, messages = {}, {}

		for _, err in ipairs(errors) do
			table.insert(messages, err.message)
			local column = err.state and view.columns[err.state]

			if column and api.nvim_buf_is_valid(column.buf) and err.row then
				by_buffer[column.buf] = by_buffer[column.buf] or {}
				table.insert(by_buffer[column.buf], {
					lnum = err.row - 1,
					col = 0,
					message = err.message,
					severity = vim.diagnostic.severity.ERROR,
				})
			end
		end

		for buf, items in pairs(by_buffer) do
			vim.diagnostic.set(effects.diagnostics, buf, items)
		end

		effects.notify(table.concat(messages, "; "))
		return nil
	end

	for id, item in pairs(view.registry) do
		paths[id], titles[id] = item.entry.path, item.title
	end

	view.saving = true
	local ok, err, text, created = tasks.apply_layout(view.ws, view.path, {
		expected_text = view.baseline_text,
		states = states,
		paths = paths,
		titles = titles,
		new_tickets = new_tickets,
		removed_tickets = removed,
		restored_tickets = restored,
	})
	view.saving = false

	if not ok then
		view.stale = storage.read(view.path) ~= view.baseline_text
		effects.decorate(view)
		effects.notify(err)
		return nil
	end

	view.baseline_text, view.stale = text, false

	-- Commit identities only into columns that have not changed since the snapshot.
	for index, column in ipairs(view.columns) do
		if api.nvim_buf_is_valid(column.buf) and api.nvim_buf_get_changedtick(column.buf) == ticks[column.buf] then
			local rows, changed = vim.deepcopy(columns[index].lines), false

			for key, ticket in pairs(created or {}) do
				local new = new_tickets[key]

				if new.state == index then
					rows[new.row] = ticket.metadata.id .. "  " .. edit.title(ticket.metadata.title)
					changed = true
				end
			end

			if changed then
				api.nvim_buf_call(column.buf, function()
					pcall(vim.cmd.undojoin)
					api.nvim_buf_set_lines(column.buf, 0, -1, false, rows)
				end)
				ticks[column.buf] = api.nvim_buf_get_changedtick(column.buf)
			end
		end
	end

	local board = tasks.read_board(view.ws, view.path)

	if board then
		view.board, view.registry = board, edit.registry(board)
	end

	for buf, tick in pairs(ticks) do
		if api.nvim_buf_is_valid(buf) and api.nvim_buf_get_changedtick(buf) == tick then
			vim.bo[buf].modified = false
		end
	end

	effects.decorate(view)
	require("aero.events").emit("tasks_view_changed", { board_path = view.path })
	return true
end

return M
