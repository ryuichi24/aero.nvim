-- The agent panel: a fixed-width column at the edge of the tab that shows the current session
-- (transcript + prompt for ACP, the terminal otherwise), so the other windows stay free for code.
local config = require("aero.config")
local session = require("aero.session")
local events = require("aero.events")

local M = {}

local api = vim.api

---@type table<integer, {win?: integer, last?: string}> tabpage -> panel window and the last session key shown
local tabs = {}

local function tab_state()
	local tab = api.nvim_get_current_tabpage()
	tabs[tab] = tabs[tab] or {}
	return tabs[tab]
end

function M.enabled()
	return config.options.panel ~= false
end

--- The panel window in the current tab, if it is open.
function M.win()
	local t = tab_state()
	if t.win and api.nvim_win_is_valid(t.win) and api.nvim_win_get_tabpage(t.win) == api.nvim_get_current_tabpage() then
		return t.win
	end
	t.win = nil
end

--- Whether `win` belongs to the panel column (the panel itself or an ACP prompt window).
function M.owns(win)
	if win == M.win() then
		return true
	end
	return vim.b[api.nvim_win_get_buf(win)].aero_chat_key ~= nil
end

local function winbar(win)
	local s = session.from_buf(api.nvim_win_get_buf(win))
	if not s then
		vim.wo[win].winbar = ""
		return
	end
	local st = session.status(s)
	local hl = ({ busy = "AeroBusy", idle = "AeroIdle", waiting = "AeroWaiting", exited = "AeroExited" })[st]
		or "AeroStopped"
	local where = vim.fn.fnamemodify(s.worktree, ":t")
	local bar = (" %%#AeroSession#%s%%* %%#AeroDim#· %s%%*  %%#%s#%s %s%%*"):format(
		(s.name:gsub("%%", "%%%%")),
		(where:gsub("%%", "%%%%")),
		hl,
		session.icon(s) or "",
		((session.activity(s) or st):gsub("%%", "%%%%"))
	)
	if vim.wo[win].winbar ~= bar then
		vim.wo[win].winbar = bar
	end
end

--- Open the panel (empty) if needed and return its window. Doesn't change focus.
function M.open()
	local win = M.win()
	if win then
		return win
	end
	local opts = config.options.panel
	local placeholder = api.nvim_create_buf(false, true)
	vim.bo[placeholder].bufhidden = "wipe"
	win = api.nvim_open_win(placeholder, false, {
		split = opts.position == "left" and "left" or "right",
		win = -1,
		width = opts.width,
	})
	vim.wo[win].winfixwidth = true
	tab_state().win = win
	events.emit("panel_opened", { win = win, tab = api.nvim_get_current_tabpage() })
	return win
end

--- Remember what the panel shows and label it. Call after a session was shown in the panel.
function M.shown(s)
	local win = M.win()
	if win and api.nvim_win_get_buf(win) == s.buf then
		tab_state().last = s.key
		winbar(win)
	end
end

function M.close()
	local win = M.win()
	if not win then
		return
	end
	-- take the prompt window along
	local s = session.from_buf(api.nvim_win_get_buf(win))
	local prompt = s and s.chat and s.chat.prompt_buf
	if prompt and api.nvim_buf_is_valid(prompt) then
		for _, w in ipairs(vim.fn.win_findbuf(prompt)) do
			if api.nvim_win_get_tabpage(w) == api.nvim_get_current_tabpage() and #api.nvim_tabpage_list_wins(0) > 1 then
				api.nvim_win_close(w, false)
			end
		end
	end
	if #api.nvim_tabpage_list_wins(0) > 1 then
		api.nvim_win_close(win, false)
	else
		return
	end
	tab_state().win = nil
	events.emit("panel_closed", { win = win, tab = api.nvim_get_current_tabpage() })
end

--- The session to show when the panel is toggled open: the last one shown in this tab,
--- else the first running session in the tab's working directory, else any running session.
local function default_session()
	local last = tab_state().last
	local cwd = vim.fn.getcwd()
	local in_cwd, any
	for _, s in ipairs(session.all()) do
		if s.key == last then
			return s
		end
		if session.is_running(s) then
			in_cwd = in_cwd or (vim.fs.normalize(s.worktree) == vim.fs.normalize(cwd) and s) or nil
			any = any or s
		end
	end
	return in_cwd or any
end

--- Show `s` in the panel, opening it if needed. Returns the window, or nil on failure.
function M.show(s)
	local panel = M.open()
	if api.nvim_win_get_buf(panel) == s.buf and session.is_running(s) then
		return panel
	end
	-- always into the panel, even if the session is also visible in some other window
	local win = session.show(s, panel, false)
	if win then
		M.shown(s)
	end
	return win
end

--- Toggle the panel. Opening it focuses the session it shows.
function M.toggle()
	if M.win() then
		return M.close()
	end
	local s = default_session()
	if not s then
		vim.notify("Aero: no session to show; start one from the dashboard", vim.log.levels.INFO)
		return
	end
	M.focus(s)
end

--- Show `s` in the panel and put the cursor in it (the prompt for ACP sessions).
function M.focus(s)
	local win = M.show(s)
	if win then
		api.nvim_set_current_win(win)
		if config.options.start_insert then
			session.enter(s)
		end
	end
end

--- Jump to the prompt (ACP) or terminal of the panel's session, opening the panel if needed.
function M.prompt()
	local win = M.win()
	local s = win and session.from_buf(api.nvim_win_get_buf(win)) or default_session()
	if not s then
		vim.notify("Aero: no session to show; start one from the dashboard", vim.log.levels.INFO)
		return
	end
	local shown = M.show(s)
	if shown then
		api.nvim_set_current_win(shown)
		session.enter(s)
	end
end

local function update_winbars()
	local busy = false
	for _, t in pairs(tabs) do
		if t.win and api.nvim_win_is_valid(t.win) then
			winbar(t.win)
			local s = session.from_buf(api.nvim_win_get_buf(t.win))
			busy = busy or (s ~= nil and session.status(s) == "busy")
		end
	end
	return busy
end

session.on_change(update_winbars)
require("aero.spinner").on_frame(update_winbars)

return M
