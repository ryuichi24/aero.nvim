-- Board dialogs and close policy. Editor callbacks keep selection, draft guards
-- and post-mutation reflow in the editing-session owner.
local api = vim.api
local tasks = require("aero.tasks")
local M = {}

function M.metadata(view, item, apply, notify)
	local fields = item and { "title", "task_type", "priority", "assignees", "tags", "due_date", "estimate" }
		or { "title", "description", "tags", "archived" }
	local data = item and item.ticket and item.ticket.metadata or view.board.metadata or {}
	vim.ui.select(fields, { prompt = "Edit metadata" }, function(field)
		if not field then
			return
		end

		vim.ui.input(
			{ prompt = field .. " (JSON value): ", default = data[field] ~= nil and vim.json.encode(data[field]) or "" },
			function(value)
				if not value or value == "" then
					return
				end

				local ok, decoded = pcall(vim.json.decode, value)

				if not ok then
					notify("enter a JSON value")
					return
				end

				apply(tasks.update_metadata, item and item.path, { [field] = decoded })
			end
		)
	end)
end

function M.states(view, state, apply)
	vim.ui.select({ "Add", "Rename", "Reorder", "Remove" }, { prompt = "Manage states" }, function(action)
		if action == "Add" or action == "Rename" and state then
			vim.ui.input(
				{ prompt = action .. " state: ", default = action == "Rename" and state.name or "" },
				function(name)
					if name and name ~= "" then
						if action == "Add" then
							apply(tasks.add_state, name)
						else
							apply(tasks.rename_state, state.name, name)
						end
					end
				end
			)
		elseif action == "Reorder" and state then
			vim.ui.input({ prompt = "State position: " }, function(value)
				if tonumber(value) then
					apply(tasks.reorder_state, state.name, tonumber(value))
				end
			end)
		elseif action == "Remove" and state then
			if #state.entries == 0 then
				apply(tasks.remove_state, state.name)
			else
				local names = {}

				for _, candidate in ipairs(view.board.states) do
					if candidate.name ~= state.name then
						table.insert(names, candidate.name)
					end
				end

				vim.ui.select(names, { prompt = "Move tickets before removing state" }, function(name)
					if name then
						apply(tasks.remove_state, state.name, name)
					end
				end)
			end
		end
	end)
end

function M.close(view)
	if view.tab and api.nvim_tabpage_is_valid(view.tab) then
		api.nvim_set_current_tabpage(view.tab)

		-- Preserve ordinary protection for modified ticket/source buffers.
		vim.cmd.tabclose()
		view.tab = nil

		if view.origin_tab and api.nvim_tabpage_is_valid(view.origin_tab) then
			api.nvim_set_current_tabpage(view.origin_tab)
		end

		return
	end

	local windows = {}

	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		for _, column in ipairs(view.columns) do
			if api.nvim_win_get_buf(win) == column.buf then
				table.insert(windows, win)
				break
			end
		end
	end

	if #windows > 0 then
		api.nvim_set_current_win(windows[1])
		vim.cmd.edit(vim.fn.fnameescape(view.path))
		vim.wo.conceallevel, vim.wo.concealcursor = vim.o.conceallevel, vim.o.concealcursor

		for index = 2, #windows do
			api.nvim_win_close(windows[index], true)
		end
	end
end

return M
