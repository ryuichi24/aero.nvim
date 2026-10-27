-- A focused, large diagram viewer, independent of the source buffer's layout.
local M = {}
local api = vim.api
local view, serial = nil, 0

local function window_config(fullscreen)
	local available = math.max(3, vim.o.lines - vim.o.cmdheight)
	local width = math.max(1, (fullscreen and vim.o.columns or math.floor(vim.o.columns * 0.85)) - 2)
	local height = math.max(1, (fullscreen and available or math.floor(available * 0.8)) - 2)
	return {
		relative = "editor",
		row = math.max(0, math.floor((available - height - 2) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width - 2) / 2)),
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Mermaid diagram ",
		title_pos = "center",
		zindex = 80,
	}
end

local function retire(image)
	if image then
		pcall(image.clear, image)
		image.window = -1
	end
end

function M.close()
	local current = view

	if not current then
		return false
	end

	view = nil
	retire(current.image)

	if current.group then
		pcall(api.nvim_del_augroup_by_id, current.group)
	end

	local owns_window = api.nvim_win_is_valid(current.win) and api.nvim_win_get_buf(current.win) == current.buf
	local focused = owns_window and api.nvim_get_current_win() == current.win

	if owns_window then
		api.nvim_win_close(current.win, true)
	end

	if api.nvim_buf_is_valid(current.buf) then
		api.nvim_buf_delete(current.buf, { force = true })
	end

	if focused and api.nvim_win_is_valid(current.origin) then
		api.nvim_set_current_win(current.origin)
	end

	if current.on_close then
		vim.schedule(current.on_close)
	end

	return true
end

local function draw()
	local current = view

	if not current or not api.nvim_win_is_valid(current.win) then
		return
	end

	local config = window_config(current.fullscreen)
	api.nvim_win_set_config(current.win, config)
	local toggle = current.fullscreen and "[Floating]" or "[Fullscreen]"
	local header = " " .. toggle .. "  [Close]  f: toggle · q/Esc: close"
	local lines = { header }

	for _ = 2, config.height do
		table.insert(lines, "")
	end

	vim.bo[current.buf].modifiable = true
	api.nvim_buf_set_lines(current.buf, 0, -1, false, lines)
	vim.bo[current.buf].modifiable = false
	current.fullscreen_columns = { 2, #toggle + 1 }
	local first, last = header:find("[Close]", 1, true)
	current.close_columns = { first, last }
	local ok, err = pcall(function()
		if not current.image then
			current.image = assert(
				require("image").from_file(current.path, {
					id = "aero-mermaid-view:" .. serial,
					namespace = "aero-mermaid-view",
					window = current.win,
					buffer = current.buf,
					x = 0,
					y = 1,
				}),
				"could not load diagram"
			)
		end

		current.image.window, current.image.buffer = current.win, current.buf

		-- The viewer must not inherit the small inline preview's global size caps.
		current.image.ignore_global_max_size = true
		current.image.max_width_window_percentage, current.image.max_height_window_percentage = 100, 100
		current.image:render({
			x = 0,
			y = 1,
			width = math.max(1, config.width - 1),
			height = math.max(1, config.height - 3),
		})
	end)

	if not ok then
		api.nvim_buf_set_extmark(current.buf, api.nvim_create_namespace("Aero.mermaid.viewer"), 0, 0, {
			virt_lines = { { { "Unable to preview diagram: " .. tostring(err):gsub("%s+", " "), "DiagnosticError" } } },
		})
	end
end

function M.toggle_fullscreen()
	if not view then
		return false
	end

	view.fullscreen = not view.fullscreen
	draw()
	return true
end

function M.click(mouse)
	if not view or mouse.winid ~= view.win or mouse.line ~= 1 then
		return false
	end

	local current = view

	if mouse.column >= view.fullscreen_columns[1] and mouse.column <= view.fullscreen_columns[2] then
		vim.schedule(function()
			if view == current then
				M.toggle_fullscreen()
			end
		end)
		return true
	elseif mouse.column >= view.close_columns[1] and mouse.column <= view.close_columns[2] then
		vim.schedule(function()
			if view == current then
				M.close()
			end
		end)
		return true
	end

	return false
end

function M.active()
	return view
end

function M.toggle(path, key, on_close)
	if view and view.key == key then
		return M.close()
	end

	M.close()
	serial = serial + 1
	local origin = api.nvim_get_current_win()
	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "aero-mermaid-preview"
	local win = api.nvim_open_win(buf, true, window_config(false))
	view = { buf = buf, win = win, origin = origin, path = path, key = key, fullscreen = false, on_close = on_close }

	for name, value in pairs({
		wrap = false,
		foldenable = false,
		number = false,
		relativenumber = false,
		cursorline = false,
		winbar = "",
	}) do
		api.nvim_set_option_value(name, value, { win = win })
	end

	for _, lhs in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", lhs, M.close, { buffer = buf, nowait = true })
	end

	for _, lhs in ipairs({ "f", "gF" }) do
		vim.keymap.set("n", lhs, M.toggle_fullscreen, { buffer = buf, nowait = true })
	end

	vim.keymap.set("n", "<LeftMouse>", function()
		return M.click(vim.fn.getmousepos()) and "" or "<LeftMouse>"
	end, { buffer = buf, expr = true })
	local group = api.nvim_create_augroup("Aero.mermaid.viewer", { clear = true })
	view.group = group
	api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			vim.schedule(draw)
		end,
	})
	api.nvim_create_autocmd("WinClosed", {
		group = group,
		pattern = tostring(win),
		callback = function()
			vim.schedule(function()
				if view and view.win == win then
					M.close()
				end
			end)
		end,
	})
	api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = buf,
		callback = function()
			vim.schedule(function()
				if view and view.buf == buf then
					M.close()
				end
			end)
		end,
	})
	draw()
	return true
end

return M
