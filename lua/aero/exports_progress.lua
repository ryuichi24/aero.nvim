-- A persistent, non-focusable status window for background export formatting.
local api = vim.api
local spinner = require("aero.spinner")
local M = {}

function M.start(name, opts)
	opts = opts or {}
	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	local started = vim.uv.now()
	local stage, bytes = opts.stage or "Starting agent", 0
	local width = math.max(1, math.min(64, vim.o.columns - 4))
	local win = api.nvim_open_win(buf, false, {
		relative = "editor",
		row = math.max(0, vim.o.lines - 6),
		col = math.max(0, vim.o.columns - width - 2),
		width = width,
		height = 2,
		style = "minimal",
		border = "rounded",
		focusable = false,
		title = opts.title or " Readable log export ",
		zindex = 60,
	})
	local timer = vim.uv.new_timer()
	local closed = false
	local function render()
		if closed or not api.nvim_buf_is_valid(buf) then
			return
		end
		local text = spinner.frame() .. " " .. stage .. " · " .. spinner.elapsed(started)
		if bytes > 0 then
			text = text .. (" · %.1f KiB received"):format(bytes / 1024)
		end
		api.nvim_buf_set_lines(buf, 0, -1, false, { text, (tostring(name):gsub("[%c]", " ")) })
		if opts.redraw then
			vim.cmd.redraw()
		end
	end
	render()
	timer:start(150, 150, vim.schedule_wrap(render))
	return {
		update = function(value, count)
			stage, bytes = value, count or bytes
			render()
		end,
		close = function()
			if closed then
				return
			end
			closed = true
			timer:stop()
			timer:close()
			if api.nvim_win_is_valid(win) then
				api.nvim_win_close(win, true)
			end
			if api.nvim_buf_is_valid(buf) then
				api.nvim_buf_delete(buf, { force = true })
			end
		end,
	}
end

return M
