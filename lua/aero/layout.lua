-- Shared repeat-resize controls and remembered sizes for Aero's panes.
local api = vim.api
local config = require("aero.config")
local M = {}
local tabs, windows, bindings = {}, {}, {}
local updating = false
local balancing = false
local pending_balance = {}
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

local function code_window(win)
	if api.nvim_win_get_config(win).relative ~= "" then
		return false
	end
	local entry = windows[win]
	if
		entry
		and (entry.kind == "dashboard" or entry.kind == "panel" or entry.kind == "prompt" or entry.kind == "terminal")
	then
		return false
	end
	local buf = api.nvim_win_get_buf(win)
	return vim.bo[buf].filetype ~= "Aero" and not vim.b[buf].aero_chat_key and not vim.b[buf].aero_term
end

local function has_code(tab)
	for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
		if code_window(win) then
			return true
		end
	end
	return false
end

function M.remember(win, manual)
	local entry = windows[win]
	if balancing or not entry or not api.nvim_win_is_valid(win) then
		return
	end
	local tab = api.nvim_win_get_tabpage(win)
	local state = tab_state(tab)
	if entry.kind == "panel" or entry.kind == "dashboard" then
		if state.screen_size and state.screen_size ~= vim.o.columns .. ":" .. vim.o.lines and not manual then
			return
		end
		if pending_balance[tab] and pending_balance[tab].screen and not manual then
			return
		end
		-- Automatic expansion after closing the editor is not a new user preference.
		if
			not has_code(tab)
			or vim.t[tab].aero_fullscreen
			or entry.auto_width == api.nvim_win_get_width(win) and not manual
		then
			return
		end
		entry.auto_width = nil
	end
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

function M.track(win, kind, key, preferred_width)
	windows[win] = { kind = kind, key = key }
	if preferred_width then
		local state = tab_state(api.nvim_win_get_tabpage(win))
		if kind == "dashboard" then
			state.dashboard_width = preferred_width
		elseif kind == "panel" then
			state.width = preferred_width
		end
	else
		M.remember(win)
	end
end

--- Resize side columns only: preserve buffers, code splits, prompt heights, and focus.
function M.rebalance()
	if vim.fn.getcmdwintype() ~= "" then
		return
	end
	if balancing or config.options.layout == false or vim.t.aero_fullscreen or vim.t.aero_board_path then
		return
	end
	tab_state().screen_size = vim.o.columns .. ":" .. vim.o.lines
	local tree = vim.fn.winlayout()
	if tree[1] ~= "row" then
		return
	end
	local sidebars, centers = {}, 0
	local side_minimum = math.max(1, vim.o.winminwidth)
	local function leaves(node, out)
		if node[1] == "leaf" then
			table.insert(out, node[2])
		else
			for _, child in ipairs(node[2]) do
				leaves(child, out)
			end
		end
	end
	for _, child in ipairs(tree[2]) do
		local group, side, code = {}, nil, false
		leaves(child, group)
		for _, win in ipairs(group) do
			local entry = windows[win]
			if entry and (entry.kind == "dashboard" or entry.kind == "panel") then
				side = { win = win, kind = entry.kind }
			end
			code = code or code_window(win)
		end
		if side and not code then
			side.preferred = math.max(side_minimum, side.kind == "dashboard" and M.dashboard_width() or M.panel_width())
			table.insert(sidebars, side)
		else
			centers = centers + 1
		end
	end
	if centers == 0 or #sidebars == 0 or not has_code(0) then
		return
	end
	local available = math.max(1, vim.o.columns - (#tree[2] - 1))
	local minimum = math.max(
		side_minimum,
		math.min(config.options.layout.min_code_width, math.floor((available - #sidebars * side_minimum) / centers))
	)
	local budget = math.max(#sidebars * side_minimum, available - centers * minimum)
	local preferred = 0
	for _, side in ipairs(sidebars) do
		preferred = preferred + side.preferred
	end
	local remaining = math.min(preferred, budget)
	for index, side in ipairs(sidebars) do
		local width = math.min(side.preferred, math.floor(side.preferred * budget / preferred))
		side.width = math.max(side_minimum, math.min(width, remaining - (#sidebars - index) * side_minimum))
		remaining = remaining - side.width
	end
	balancing = true
	-- Release excess width before growing either neighbor.
	for _, side in ipairs(sidebars) do
		if api.nvim_win_get_width(side.win) > side.width then
			pcall(api.nvim_win_set_width, side.win, side.width)
		end
	end
	for _, side in ipairs(sidebars) do
		if api.nvim_win_get_width(side.win) ~= side.width then
			pcall(api.nvim_win_set_width, side.win, side.width)
		end
	end
	for win, entry in pairs(windows) do
		if
			api.nvim_win_is_valid(win)
			and api.nvim_win_get_tabpage(win) == api.nvim_get_current_tabpage()
			and (entry.kind == "panel" or entry.kind == "dashboard")
		then
			entry.auto_width = api.nvim_win_get_width(win)
		end
	end
	balancing = false
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
		M.remember(w, true)
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
api.nvim_create_autocmd({ "WinNew", "WinClosed", "VimResized", "TabEnter", "CmdwinLeave" }, {
	group = group,
	callback = function(event)
		local tab = api.nvim_get_current_tabpage()
		if event.event == "TabEnter" and tab_state(tab).screen_size == vim.o.columns .. ":" .. vim.o.lines then
			return
		end
		local screen = event.event == "VimResized" or event.event == "TabEnter"
		if pending_balance[tab] then
			pending_balance[tab].screen = pending_balance[tab].screen or screen
			return
		end
		pending_balance[tab] = { screen = screen }
		vim.schedule(function()
			pending_balance[tab] = nil
			if api.nvim_tabpage_is_valid(tab) and api.nvim_get_current_tabpage() == tab then
				M.rebalance()
			end
		end)
	end,
})
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
