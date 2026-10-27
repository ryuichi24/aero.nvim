-- Apply prepared tree rows to a dashboard buffer, retaining selection by identity.
local api = vim.api
local M = {}
local ns = api.nvim_create_namespace("Aero")

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
end

return M
