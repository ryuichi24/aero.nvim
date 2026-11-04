-- Reading slots belong to the reader panel, never to Neovim's tabline.
local api = vim.api
local M = {}
local states = {}
local returns = {}
local workspace_kinds = { "source", "exports", "references", "reports", "reading", "browser" }
local knowledge_kinds = { "content", "metadata" }
local labels = {
	source = "Source",
	exports = "Exported logs",
	references = "References",
	reports = "Reports",
	reading = "Reading",
	browser = "Browser",
	content = "Extracted content",
	metadata = "Metadata",
}
local changing = false
local browser_options = { "number", "relativenumber", "signcolumn", "foldcolumn", "statuscolumn", "wrap" }

local function valid(win)
	return win
		and api.nvim_win_is_valid(win)
		and not vim.w[win].aero_reading_note
		and api.nvim_win_get_tabpage(win) == api.nvim_get_current_tabpage()
		and api.nvim_win_get_config(win).relative == ""
		and vim.bo[api.nvim_win_get_buf(win)].buftype ~= "quickfix"
		and vim.bo[api.nvim_win_get_buf(win)].filetype ~= "Aero"
		and not require("aero.panel").owns(win)
		and not require("aero.terminal").is_term_win(win)
end

local function state()
	local tab = api.nvim_get_current_tabpage()
	local knowledge = vim.t.aero_knowledge_reader
	local key = knowledge and ("knowledge:" .. knowledge.space_id .. ":" .. knowledge.source_id)
		or vim.t.aero_worktree
		or tab
	states[tab] = states[tab] or {}
	states[tab][key] = states[tab][key]
		or { mode = "tabs", slots = {}, active = knowledge and "content" or "source", knowledge = knowledge ~= nil }
	return states[tab][key]
end

local function kinds(s)
	return s.knowledge and knowledge_kinds or workspace_kinds
end

local function save(slot)
	if slot and valid(slot.win) and api.nvim_win_get_buf(slot.win) == slot.buf then
		slot.view = api.nvim_win_call(slot.win, vim.fn.winsaveview)
		slot.options = {}

		for _, name in ipairs(browser_options) do
			slot.options[name] = vim.wo[slot.win][name]
		end
	end
end

local function show(slot, win)
	slot.win = win
	api.nvim_win_set_buf(win, slot.buf)

	for name, value in pairs(slot.options or {}) do
		vim.wo[win][name] = value
	end

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
	local tabs = kinds(s)

	for kind, slot in pairs(s.slots) do
		if valid(slot.win) then
			local bar = {}

			for index, name in ipairs(tabs) do
				local hl = name == kind and "TabLineSel" or "TabLine"
				bar[#bar + 1] = "%#" .. hl .. "#%" .. index .. "@v:lua.AeroReaderClick@ " .. labels[name] .. " %T"
			end

			bar[#bar + 1] = "%#TabLineFill#%=%#TabLine#%"
				.. (#tabs + 1)
				.. "@v:lua.AeroReaderClick@ "
				.. s.mode
				.. " ⇄ %T"
			vim.wo[slot.win].winbar = table.concat(bar)
		end
	end
end

function M.attach(win, kind)
	if
		not vim.t.aero_knowledge_reader and (not vim.t.aero_worktree or vim.t.aero_fullscreen or vim.t.aero_board_path)
	then
		return win
	end

	local s = state()
	kind = kind or (s.knowledge and s.active or "source")

	if not vim.tbl_contains(kinds(s), kind) then
		return win
	end

	changing = true
	local previous = s.slots[s.active]
	save(previous)

	if previous and valid(previous.win) and api.nvim_win_get_buf(previous.win) == previous.buf then
		require("aero.buffers").remember(previous.win)
	end

	if not next(s.slots) and not s.knowledge then
		s.slots.source = { buf = api.nvim_win_get_buf(win), win = win }
		previous = s.slots.source
		save(previous)
	end

	local slot = s.slots[kind]

	if not slot or not api.nvim_buf_is_valid(slot.buf) then
		slot = {
			buf = api.nvim_create_buf(true, false),
			options = vim.deepcopy(s.slots.source and s.slots.source.options),
		}
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

	if kind == "browser" then
		require("aero.browser").show(win)
		slot.buf = api.nvim_win_get_buf(win)
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		vim.wo[win].signcolumn = "no"
		vim.wo[win].foldcolumn = "0"
		vim.wo[win].statuscolumn = ""
		vim.wo[win].wrap = vim.bo[slot.buf].filetype ~= "aero-browser"
	end

	return win
end

function M.open_knowledge(space_id, source_id, kind, buf)
	local tab = api.nvim_get_current_tabpage()
	local active = M.active()
	M.remember()
	local win = require("aero.navigation").code_window(active)

	if not returns[tab] then
		returns[tab] = {
			buf = api.nvim_win_get_buf(win),
			kind = active,
			winbar = vim.wo[win].winbar,
			reader_kind = vim.w[win].aero_reader_kind,
			view = api.nvim_win_call(win, vim.fn.winsaveview),
		}
	end

	vim.t.aero_knowledge_reader = { space_id = space_id, source_id = source_id }
	local s = state()
	s.slots[kind] = s.slots[kind] or {}
	s.slots[kind].buf = buf
	win = M.attach(win, kind)
	api.nvim_set_current_win(win)
	return win
end

function M.close_knowledge()
	if not vim.t.aero_knowledge_reader then
		return
	end

	local tab = api.nvim_get_current_tabpage()
	local s, previous = state(), returns[tab]
	M.remember()
	local win = s.win
	changing = true

	for _, slot in pairs(s.slots) do
		if valid(slot.win) and slot.win ~= win and api.nvim_win_get_buf(slot.win) == slot.buf then
			api.nvim_win_close(slot.win, false)
		end

		slot.win = nil
	end

	vim.t.aero_knowledge_reader = nil
	returns[tab] = nil
	changing = false

	if not valid(win) then
		return
	end

	if vim.t.aero_worktree and not vim.t.aero_fullscreen and not vim.t.aero_board_path then
		win = M.attach(win, previous and previous.kind or "source")
	else
		api.nvim_win_set_buf(
			win,
			previous and api.nvim_buf_is_valid(previous.buf) and previous.buf or api.nvim_create_buf(true, false)
		)
		vim.wo[win].winbar = previous and previous.winbar or ""
		vim.w[win].aero_reader_kind = previous and previous.reader_kind or nil

		if previous then
			api.nvim_win_call(win, function()
				vim.fn.winrestview(previous.view)
			end)
		end
	end

	api.nvim_set_current_win(win)
end

function M.select(kind)
	if not labels[kind] then
		return
	end

	local knowledge = vim.t.aero_knowledge_reader

	if vim.tbl_contains(knowledge_kinds, kind) then
		if knowledge then
			local metadata = require("aero.knowledge.metadata")
			local open = kind == "content" and metadata.extracted_content or metadata.extraction_details
			return open(knowledge.space_id, knowledge.source_id)
		end

		return
	elseif knowledge then
		M.close_knowledge()
	end

	local win = require("aero.navigation").code_window(kind)
	api.nvim_set_current_win(win)
end

function M.mode(mode)
	local s = state()
	mode = mode or (s.mode == "tabs" and "panes" or "tabs")

	if mode ~= "tabs" and mode ~= "panes" then
		return vim.notify(
			"Aero: use :Aero reader [tabs|panes|source|exports|references|reports|reading|browser|content|metadata]",
			vim.log.levels.WARN
		)
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

		for _, kind in ipairs(kinds(s)) do
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
		local tabs = kinds(state())

		if index == #tabs + 1 then
			M.mode()
		else
			M.select(tabs[index])
		end
	end
	local group = api.nvim_create_augroup("Aero.reader", { clear = true })
	api.nvim_create_autocmd({ "BufEnter", "WinEnter" }, {
		group = group,
		callback = function()
			if
				changing
				or (not vim.t.aero_worktree and not vim.t.aero_knowledge_reader)
				or not valid(api.nvim_get_current_win())
			then
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
					returns[tab] = nil
				end
			end
		end,
	})
end

return M
