-- Reading slots belong to the reader panel, never to Neovim's tabline.
local api = vim.api
local M = {}
local states = {}
local kinds = { "source", "exports", "references", "reports" }
local labels = { source = "Source", exports = "Exported logs", references = "References", reports = "Reports" }
local changing = false

local function valid(win)
	return win
		and api.nvim_win_is_valid(win)
		and api.nvim_win_get_tabpage(win) == api.nvim_get_current_tabpage()
		and api.nvim_win_get_config(win).relative == ""
		and vim.bo[api.nvim_win_get_buf(win)].filetype ~= "Aero"
		and not require("aero.panel").owns(win)
		and not require("aero.terminal").is_term_win(win)
end

local function state()
	local tab = api.nvim_get_current_tabpage()
	local key = vim.t.aero_worktree or tab
	states[tab] = states[tab] or {}
	states[tab][key] = states[tab][key] or { mode = "tabs", slots = {}, active = "source" }
	return states[tab][key]
end

local function save(slot)
	if slot and valid(slot.win) and api.nvim_win_get_buf(slot.win) == slot.buf then
		slot.view = api.nvim_win_call(slot.win, vim.fn.winsaveview)
	end
end

local function show(slot, win)
	slot.win = win
	api.nvim_win_set_buf(win, slot.buf)
	if slot.view then
		api.nvim_win_call(win, function()
			vim.fn.winrestview(slot.view)
		end)
	end
end

function M.active()
	return state().active
end

function M.remember()
	for _, slot in pairs(state().slots) do
		save(slot)
	end
end

local function render(s)
	for kind, slot in pairs(s.slots) do
		if valid(slot.win) then
			local bar = {}
			for index, name in ipairs(kinds) do
				local hl = name == kind and "TabLineSel" or "TabLine"
				bar[#bar + 1] = "%#" .. hl .. "#%" .. index .. "@v:lua.AeroReaderClick@ " .. labels[name] .. " %T"
			end
			bar[#bar + 1] = "%#TabLineFill#%=%#TabLine#%5@v:lua.AeroReaderClick@ " .. s.mode .. " ⇄ %T"
			vim.wo[slot.win].winbar = table.concat(bar)
		end
	end
end

function M.attach(win, kind)
	if not vim.t.aero_worktree or vim.t.aero_fullscreen or vim.t.aero_board_path then
		return win
	end
	kind = kind or "source"
	local s = state()
	changing = true
	local previous = s.slots[s.active]
	save(previous)
	if previous and valid(previous.win) and api.nvim_win_get_buf(previous.win) == previous.buf then
		require("aero.buffers").remember(previous.win)
	end
	if not next(s.slots) then
		s.slots.source = { buf = api.nvim_win_get_buf(win), win = win }
		previous = s.slots.source
	end
	local slot = s.slots[kind]
	if not slot or not api.nvim_buf_is_valid(slot.buf) then
		slot = { buf = api.nvim_create_buf(true, false) }
		s.slots[kind] = slot
	end
	if s.mode == "tabs" then
		win = valid(s.win) and s.win or win
		for _, other in pairs(s.slots) do
			other.win = nil
		end
	elseif valid(slot.win) then
		win = slot.win
	elseif previous and valid(previous.win) then
		win = api.nvim_open_win(slot.buf, false, { split = "below", win = previous.win })
	end
	s.win, s.active = win, kind
	-- Buffer events during the swap must not record the outgoing document as Source.
	vim.w[win].aero_reader_kind = "switching"
	show(slot, win)
	vim.w[win].aero_reader_kind = kind
	render(s)
	changing = false
	return win
end

function M.select(kind)
	if not labels[kind] then
		return
	end
	local win = require("aero.navigation").code_window(kind)
	api.nvim_set_current_win(win)
end

function M.mode(mode)
	local s = state()
	mode = mode or (s.mode == "tabs" and "panes" or "tabs")
	if mode ~= "tabs" and mode ~= "panes" then
		return vim.notify("Aero: use :Aero reader [tabs|panes|source|exports|references|reports]", vim.log.levels.WARN)
	end
	if not next(s.slots) then
		require("aero.navigation").code_window()
	end
	if s.mode == mode then
		return
	end
	changing = true
	local active = s.slots[s.active]
	local anchor = active and active.win
	if not valid(anchor) then
		changing = false
		return
	end
	for _, slot in pairs(s.slots) do
		save(slot)
	end
	s.mode = mode
	if mode == "tabs" then
		for _, slot in pairs(s.slots) do
			if valid(slot.win) and slot.win ~= anchor then
				api.nvim_win_close(slot.win, false)
			end
			slot.win = nil
		end
		active.win = anchor
	else
		local last = anchor
		for _, kind in ipairs(kinds) do
			local slot = s.slots[kind]
			if slot and slot ~= active and api.nvim_buf_is_valid(slot.buf) then
				last = api.nvim_open_win(slot.buf, false, { split = "below", win = last })
				show(slot, last)
				vim.w[last].aero_reader_kind = kind
			end
		end
	end
	s.win = anchor
	render(s)
	changing = false
	api.nvim_set_current_win(anchor)
end

function M.setup()
	_G.AeroReaderClick = function(index)
		if index == 5 then
			M.mode()
		else
			M.select(kinds[index])
		end
	end
	local group = api.nvim_create_augroup("Aero.reader", { clear = true })
	api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
		group = group,
		callback = function()
			if changing or not vim.t.aero_worktree or not valid(api.nvim_get_current_win()) then
				return
			end
			local s, win = state(), api.nvim_get_current_win()
			for kind, slot in pairs(s.slots) do
				if slot.win == win then
					s.active, s.win = kind, win
					slot.buf = api.nvim_win_get_buf(win)
					render(s)
					break
				end
			end
		end,
	})
	api.nvim_create_autocmd("TabClosed", {
		group = group,
		callback = function()
			for tab in pairs(states) do
				if not api.nvim_tabpage_is_valid(tab) then
					states[tab] = nil
				end
			end
		end,
	})
end

return M
