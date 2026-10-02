-- Shared repeat-resize controls and remembered sizes for Aero's panes.
local api = vim.api
local config = require("aero.config")
local M = {}
local tabs, windows, bindings = {}, {}, {}
local updating = false
local resize_mode
local resize_ns = api.nvim_create_namespace("Aero.resize")
local directions = {
	grow = { 1, "height" },
	shrink = { -1, "height" },
	narrow = { -1, "width" },
	widen = { 1, "width" },
}

local function stop_resize()
	if not resize_mode then
		return
	end
	local mode = resize_mode
	resize_mode = nil
	vim.on_key(nil, resize_ns)
	if not api.nvim_buf_is_valid(mode.buf) then
		return
	end
	for _, key in ipairs(mode.keys) do
		vim.keymap.del("n", key, { buffer = mode.buf })
		local saved = mode.saved[key]
		if saved then
			api.nvim_buf_call(mode.buf, function()
				vim.fn.mapset("n", false, saved)
			end)
		end
	end
end

local function tab_state(tab)
	tab = tab or api.nvim_get_current_tabpage()
	tabs[tab] = tabs[tab] or { prompts = {}, terminals = {} }
	return tabs[tab]
end

function M.panel_width()
	return tab_state().width or config.options.panel.width
end

function M.prompt_height(key)
	return tab_state().prompts[key] or config.options.acp.prompt_height
end

function M.dashboard_width()
	return tab_state().dashboard_width or config.options.dashboard.width
end

function M.terminal_height(key)
	return tab_state().terminals[key] or config.options.terminal.height
end

function M.keys(prompt)
	local resize = config.options.resize
	local keys = false
	if resize then
		keys = {}
		for name in pairs(directions) do
			local key = resize.keys[name]
			keys[name] = key and (resize.prefix .. key) or false
		end
	end
	-- Keep the previous explicit-chord configuration supported.
	if config.options.resize_keys ~= nil then
		if config.options.resize_keys == false then
			keys = false
		else
			keys = vim.tbl_extend("force", keys or {}, config.options.resize_keys)
		end
	end
	if prompt and config.options.acp.resize_keys ~= nil then
		if config.options.acp.resize_keys == false then
			return false
		end
		return vim.tbl_extend("force", keys or {}, config.options.acp.resize_keys)
	end
	return keys
end

function M.remember(win)
	local entry = windows[win]
	if not entry or not api.nvim_win_is_valid(win) then
		return
	end
	local state = tab_state(api.nvim_win_get_tabpage(win))
	if entry.kind == "panel" then
		state.width = api.nvim_win_get_width(win)
	elseif entry.kind == "prompt" then
		state.prompts[entry.key] = api.nvim_win_get_height(win)
	elseif entry.kind == "dashboard" then
		-- A fullscreen dashboard should not replace the sidebar's width.
		if not vim.t[api.nvim_win_get_tabpage(win)].aero_fullscreen then
			state.dashboard_width = api.nvim_win_get_width(win)
		end
	elseif entry.kind == "terminal" then
		state.terminals[entry.key] = api.nvim_win_get_height(win)
	end
end

function M.track(win, kind, key)
	windows[win] = { kind = kind, key = key }
	M.remember(win)
end

--- Enter a buffer-local repeat mode: h/j/k/l resize until another key or window is used.
function M.resize(delta, axis)
	local win = api.nvim_get_current_win()
	local buf = api.nvim_win_get_buf(win)
	if axis == "width" then
		api.nvim_win_set_width(win, math.max(1, api.nvim_win_get_width(win) + delta))
	else
		api.nvim_win_set_height(win, math.max(1, api.nvim_win_get_height(win) + delta))
	end
	-- Resizing one split also changes its neighbors.
	for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
		M.remember(w)
	end
	if resize_mode and resize_mode.win == win then
		return
	end
	stop_resize()
	resize_mode = { win = win, buf = buf, saved = {}, keys = {}, allowed = {} }
	local repeat_keys = config.options.resize and config.options.resize.keys or config.defaults.resize.keys
	for name, resize in pairs(directions) do
		local key = repeat_keys[name]
		if key then
			table.insert(resize_mode.keys, key)
			table.insert(resize_mode.allowed, api.nvim_replace_termcodes(key, true, false, true))
			local saved = vim.fn.maparg(key, "n", false, true)
			if saved.buffer == 1 then
				resize_mode.saved[key] = saved
			end
			vim.keymap.set("n", key, function()
				M.resize(resize[1], resize[2])
			end, { buffer = buf, nowait = true, desc = "Aero: resize pane (any other key exits)" })
		end
	end
	vim.on_key(function(_, typed)
		if typed ~= "" and resize_mode then
			for _, key in ipairs(resize_mode.allowed) do
				if vim.startswith(key, typed) then
					return
				end
			end
			stop_resize()
		end
	end, resize_ns)
end

local function unbind(buf)
	local maps = bindings[buf]
	bindings[buf] = nil
	if not maps or not api.nvim_buf_is_valid(buf) then
		return
	end
	updating = true
	api.nvim_buf_call(buf, function()
		for _, map in ipairs(maps) do
			local current = vim.fn.maparg(map.key, "n", false, true)
			if current.callback == map.callback then
				vim.keymap.del("n", map.key, { buffer = buf })
				if map.saved then
					vim.fn.mapset("n", false, map.saved)
				end
			end
		end
	end)
	updating = false
end

function M.bind(buf, code)
	if bindings[buf] then
		return
	end
	local keys = M.keys(vim.b[buf].aero_chat_key ~= nil)
	if not keys then
		return
	end
	local maps = { code = code }
	bindings[buf] = maps
	updating = true
	api.nvim_buf_call(buf, function()
		for name, size in pairs(directions) do
			local key = keys[name]
			if key then
				local previous = vim.fn.maparg(key, "n", false, true)
				local callback = function()
					M.resize(size[1], size[2])
				end
				table.insert(maps, {
					key = key,
					callback = callback,
					saved = previous.buffer == 1 and previous or nil,
				})
				vim.keymap.set("n", key, callback, {
					buffer = buf,
					nowait = true,
					desc = "Aero: " .. name .. " pane",
				})
			end
		end
	end)
	updating = false
end

local function aero_buf(buf)
	local b = vim.b[buf]
	return b.aero_session or b.aero_chat_key or b.aero_term or vim.bo[buf].filetype == "Aero"
end

local function bind_current()
	if updating then
		return
	end
	local buf = api.nvim_get_current_buf()
	if aero_buf(buf) then
		M.bind(buf)
		return
	end
	local in_aero = vim.t.aero_worktree ~= nil
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		in_aero = in_aero or aero_buf(api.nvim_win_get_buf(win))
	end
	local bo = vim.bo[buf]
	if in_aero and (bo.buftype == "" or bo.filetype == "oil" or bo.filetype == "netrw") then
		M.bind(buf, true)
	elseif bindings[buf] and bindings[buf].code then
		unbind(buf)
	end
end

function M.setup()
	stop_resize()
	local old = {}
	for buf, maps in pairs(bindings) do
		old[buf] = { code = maps.code }
	end
	for buf in pairs(old) do
		unbind(buf)
	end
	for buf, maps in pairs(old) do
		if api.nvim_buf_is_valid(buf) then
			M.bind(buf, maps.code)
		end
	end
	bind_current()
end

local group = api.nvim_create_augroup("Aero.layout", { clear = true })
api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
	group = group,
	callback = bind_current,
})
api.nvim_create_autocmd("BufWipeout", {
	group = group,
	callback = function(event)
		bindings[event.buf] = nil
	end,
})
api.nvim_create_autocmd("WinResized", {
	group = group,
	callback = function()
		for _, win in ipairs(vim.v.event.windows or {}) do
			M.remember(win)
		end
	end,
})
-- Capture the final size before :close, prompt submission, or replacing a buffer.
api.nvim_create_autocmd({ "WinLeave", "BufWinLeave" }, {
	group = group,
	callback = function()
		for win in pairs(windows) do
			M.remember(win)
		end
		stop_resize()
	end,
})
api.nvim_create_autocmd("ModeChanged", {
	group = group,
	callback = stop_resize,
})
api.nvim_create_autocmd("WinClosed", {
	group = group,
	callback = function(event)
		windows[tonumber(event.match)] = nil
	end,
})
api.nvim_create_autocmd("TabClosed", {
	group = group,
	callback = function()
		for tab in pairs(tabs) do
			if not api.nvim_tabpage_is_valid(tab) then
				tabs[tab] = nil
			end
		end
	end,
})

return M
