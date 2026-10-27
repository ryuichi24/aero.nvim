-- Board-only window geometry. Reflow preserves column buffers and never reads files.
local api = vim.api
local M = {}

function M.geometry(view)
	local dimensions = { vim.o.columns, vim.o.lines }

	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		for _, column in ipairs(view.columns) do
			if api.nvim_win_get_buf(win) == column.buf then
				vim.list_extend(dimensions, { win, api.nvim_win_get_width(win), api.nvim_win_get_height(win) })
				break
			end
		end
	end

	return table.concat(dimensions, ":")
end

function M.reflow(view, focus, resized, decorate)
	if vim.fn.getcmdwintype() ~= "" then
		return
	end

	if #view.columns == 0 then
		vim.notify("Aero tasks: board has no states; edit its source", vim.log.levels.WARN)
		return
	end

	local windows, width = {}, 0

	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		for _, column in ipairs(view.columns) do
			if api.nvim_win_get_buf(win) == column.buf then
				table.insert(windows, win)
				width = width + api.nvim_win_get_width(win) + 1
				break
			end
		end
	end

	if #windows == 0 then
		local win = api.nvim_get_current_win()
		api.nvim_win_set_buf(win, view.columns[1].buf)
		windows, width = { win }, api.nvim_win_get_width(win)
	end

	local normal_windows = 0

	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if api.nvim_win_get_config(win).relative == "" then
			normal_windows = normal_windows + 1
		end
	end

	if #windows == normal_windows then
		width = vim.o.columns
	end

	local count = math.max(
		1,
		math.min(#view.columns, math.floor(width / math.max(12, require("aero.config").options.tasks.column_width)))
	)
	focus = math.max(1, math.min(focus or 1, #view.columns))
	local tab, target = api.nvim_get_current_tabpage()

	for _, column in ipairs(view.columns) do
		column.cursors = column.cursors or {}

		for _, win in ipairs(windows) do
			if api.nvim_win_get_buf(win) == column.buf then
				column.cursors[tab] = api.nvim_win_get_cursor(win)

				if column == view.columns[focus] then
					target = win
				end
			end
		end
	end

	if target and #windows == count then
		for _, win in ipairs(windows) do
			vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false

			if resized then
				pcall(api.nvim_win_set_width, win, math.max(1, math.floor(width / count) - 1))
			end
		end

		api.nvim_set_current_win(target)
	else
		local first = math.max(1, math.min(focus, #view.columns - count + 1))
		local anchor = windows[1]

		for index = #windows, 2, -1 do
			api.nvim_win_close(windows[index], true)
		end

		api.nvim_win_set_buf(anchor, view.columns[first].buf)
		local displayed = { anchor }

		for offset = 1, count - 1 do
			table.insert(
				displayed,
				api.nvim_open_win(
					view.columns[first + offset].buf,
					false,
					{ split = "right", win = displayed[#displayed] }
				)
			)
		end

		for index, win in ipairs(displayed) do
			vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false
			pcall(api.nvim_win_set_width, win, math.max(1, math.floor(width / count) - 1))
			local cursor = view.columns[first + index - 1].cursors[tab]

			if cursor then
				pcall(api.nvim_win_set_cursor, win, cursor)
			end
		end

		api.nvim_set_current_win(displayed[focus - first + 1])
	end

	decorate(view)
	view.geometry = M.geometry(view)
end

return M
