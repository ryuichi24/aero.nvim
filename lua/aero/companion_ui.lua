-- Local operator UI; pairing codes never need to be copied from process logs.
local M = {}
local api = vim.api
local buffer, window, last_info, last_actions
local ns = api.nvim_create_namespace("Aero.companion")

local function clean(text)
	return tostring(text or ""):gsub("[%z\1-\31\127]", " ")
end

function M.close()
	if window and api.nvim_win_is_valid(window) then
		api.nvim_win_close(window, true)
	end
	if buffer and api.nvim_buf_is_valid(buffer) then
		api.nvim_buf_delete(buffer, { force = true })
	end
	window, buffer, last_info = nil, nil, nil
	local actions = last_actions
	last_actions = nil
	if actions and actions.closed then
		actions.closed()
	end
end

function M.window()
	return window
end

function M.show(info, actions, enter)
	if not enter and not (window and api.nvim_win_is_valid(window)) then
		return
	end
	last_info, last_actions = info, actions
	local devices = info.devices or {}
	local lines = { "Aero mobile companion", "", "Open on your phone:", "  " .. clean(info.origin), "" }
	if info.starting then
		table.insert(lines, "Starting the web bridge…")
	elseif info.code and info.code:match("^%d%d%d%d%d%d$") and (info.expires_at or 0) > os.time() then
		table.insert(lines, "Pairing code (6 digits):")
		table.insert(lines, "         " .. info.code)
		table.insert(lines, "Valid until " .. os.date("%H:%M", info.expires_at) .. " · single use")
	else
		table.insert(lines, "Pairing code used or expired. Press p for a new code.")
	end
	vim.list_extend(
		lines,
		{ "", "Previously paired phones reconnect automatically.", "", "Remembered devices: " .. #devices }
	)
	if #devices == 0 then
		table.insert(lines, "  None yet.")
	end
	for _, device in ipairs(devices) do
		table.insert(
			lines,
			"  " .. clean(device.name ~= "" and device.name or "Phone") .. "  [" .. clean(device.id) .. "]"
		)
	end
	vim.list_extend(
		lines,
		{ "", "p: new code · r: revoke device · y: copy URL", "s: stop companion · q/Esc: close this popup" }
	)
	if not (buffer and api.nvim_buf_is_valid(buffer)) then
		buffer = api.nvim_create_buf(false, true)
		vim.bo[buffer].bufhidden = "wipe"
		vim.bo[buffer].filetype = "aero_companion"
		vim.bo[buffer].swapfile = false
		local function map(key, callback)
			vim.keymap.set("n", key, callback, { buffer = buffer, nowait = true, silent = true })
		end
		map("q", M.close)
		map("<Esc>", M.close)
		map("p", function()
			if last_actions then
				last_actions.pair()
			end
		end)
		map("r", function()
			if last_actions then
				last_actions.revoke()
			end
		end)
		map("s", function()
			if last_actions then
				last_actions.stop()
			end
		end)
		map("y", function()
			if last_info then
				vim.fn.setreg('"', last_info.origin or "")
				vim.notify("Aero: companion URL copied")
			end
		end)
	end
	vim.bo[buffer].modifiable = true
	api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
	vim.bo[buffer].modifiable = false
	api.nvim_buf_clear_namespace(buffer, ns, 0, -1)
	api.nvim_buf_set_extmark(buffer, ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
	for index, line in ipairs(lines) do
		if line:match("^%s*%d%d%d%d%d%d$") then
			api.nvim_buf_set_extmark(buffer, ns, index - 1, 0, { end_col = #line, hl_group = "DiagnosticOk" })
		end
	end
	local width = math.max(1, math.min(76, vim.o.columns - 4))
	local height = math.max(1, math.min(#lines, vim.o.lines - 5))
	local options = {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height - 2) / 2)),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
		style = "minimal",
		border = "rounded",
		title = " Aero companion ",
		title_pos = "center",
	}
	if window and api.nvim_win_is_valid(window) then
		api.nvim_win_set_buf(window, buffer)
		api.nvim_win_set_config(window, options)
		if enter then
			api.nvim_set_current_win(window)
		end
	else
		window = api.nvim_open_win(buffer, enter == true, options)
	end
	vim.wo[window].wrap, vim.wo[window].linebreak = true, true
	if info.code and (info.expires_at or 0) > os.time() then
		vim.defer_fn(function()
			if last_info == info then
				M.show(info, actions, false)
			end
		end, math.max(1, (info.expires_at - os.time() + 1) * 1000))
	end
end

function M.revoke(devices, callback)
	if #devices == 0 then
		vim.notify("Aero: no remembered devices to revoke")
		return
	end
	vim.ui.select(devices, {
		prompt = "Aero: select a device to revoke",
		format_item = function(device)
			return clean(device.name) .. " [" .. clean(device.id) .. "]"
		end,
	}, function(device)
		if device then
			callback(device.id)
		end
	end)
end

return M
