-- Remember pane sizes for the lifetime of each Aero tab.
local api = vim.api
local config = require("aero.config")
local M = {}
local tabs, windows = {}, {}

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

local group = api.nvim_create_augroup("Aero.layout", { clear = true })
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
	end,
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
