-- Path suggestions keep the typed query visible, including wrapped prompt lines.
local M = {}
local api = vim.api
local active

function M.close()
	local menu = active
	active = nil
	if menu and api.nvim_win_is_valid(menu.win) then api.nvim_win_close(menu.win, true) end
end

function M.visible(buf)
	return active and active.buf == buf and api.nvim_win_is_valid(active.win)
end

function M.show(buf, start, items)
	M.close()
	if #items == 0 then return end
	local parent = api.nvim_get_current_win()
	local cursor = api.nvim_win_get_cursor(parent)
	local pos = vim.fn.screenpos(parent, cursor[1], cursor[2] + 1)
	local first = vim.fn.screenpos(parent, cursor[1], 1)
	local info = vim.fn.getwininfo(parent)[1]
	local origin = api.nvim_win_get_position(parent)
	local bottom = origin[1] + api.nvim_win_get_height(parent)
	local below = bottom - pos.row
	local height = math.min(8, #items)
	local row
	if below > 0 then
		height = math.min(height, below)
		row = pos.row
	else
		-- Above the entire wrapped line, rather than on top of its earlier text.
		height = math.min(height, math.max(0, first.row - 1))
		row = first.row - 1 - height
	end
	if height < 1 then return end
	local width = math.max(1, api.nvim_win_get_width(parent) - info.textoff - 2)
	local col = origin[2] + info.textoff
	local list = api.nvim_create_buf(false, true)
	vim.bo[list].bufhidden = "wipe"
	local lines = {}
	for _, item in ipairs(require("aero.acp.completion").fit(items, width)) do
		lines[#lines + 1] = item.abbr .. (item.menu ~= "" and "  " .. item.menu or "")
	end
	api.nvim_buf_set_lines(list, 0, -1, false, lines)
	vim.bo[list].modifiable = false
	local win = api.nvim_open_win(list, false, {
		relative = "editor", row = row, col = col, width = width, height = height,
		style = "minimal", focusable = false, noautocmd = true, zindex = 100,
	})
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true
	vim.wo[win].winhighlight = "Normal:Pmenu,CursorLine:PmenuSel"
	active = { buf = buf, parent = parent, win = win, items = items, index = 1,
		row = cursor[1], start = start - 1, finish = cursor[2], tick = api.nvim_buf_get_changedtick(buf) }
end

function M.move(buf, delta)
	if not M.visible(buf) then return end
	active.index = (active.index - 1 + delta) % #active.items + 1
	api.nvim_win_set_cursor(active.win, { active.index, 0 })
end

function M.accept(buf)
	if not M.visible(buf) then return false end
	local menu = active
	M.close()
	if api.nvim_get_current_buf() ~= buf or api.nvim_buf_get_changedtick(buf) ~= menu.tick then return true end
	local word = menu.items[menu.index].word
	api.nvim_buf_set_text(buf, menu.row - 1, menu.start, menu.row - 1, menu.finish, { word })
	api.nvim_win_set_cursor(menu.parent, { menu.row, menu.start + #word })
	return true
end

return M
