-- Worktree and code-window navigation. The dashboard registers its view context;
-- commands can navigate without importing a tree renderer.
local api = vim.api
local config = require("aero.config")
local panel = require("aero.panel")
local terminal = require("aero.terminal")
local tabs = require("aero.tabs")
local M = {}
local dashboard = { state = {} }

function M.set_dashboard(context)
	dashboard = context
end

function M.code_window(kind)
	local state = dashboard.state
	if config.options.dashboard.position == "current" then
		return state.win
	end
	local function usable(win)
		return win ~= state.win
			and api.nvim_win_get_config(win).relative == ""
			and not (panel.enabled() and panel.owns(win))
			and not terminal.is_term_win(win)
	end
	local windows = api.nvim_tabpage_list_wins(0)
	local target = require("aero.buffers").code_win() or state.target
	if target and api.nvim_win_is_valid(target) and vim.tbl_contains(windows, target) and usable(target) then
		require("aero.layout").rebalance()
		return require("aero.reader").attach(target, kind)
	end
	for _, win in ipairs(windows) do
		if usable(win) then
			require("aero.layout").rebalance()
			return require("aero.reader").attach(win, kind)
		end
	end
	local dashboard_open = state.win and api.nvim_win_is_valid(state.win)
	local panel_position = panel.enabled() and config.options.panel.position or "right"
	local side = dashboard_open and (config.options.dashboard.position == "right" and "left" or "right")
		or (panel_position == "left" and "right" or "left")
	local win = api.nvim_open_win(
		api.nvim_create_buf(false, true),
		false,
		{ split = side, win = dashboard_open and state.win or panel.win() }
	)
	vim.wo[win].winfixwidth = false
	require("aero.layout").rebalance()
	return require("aero.reader").attach(win, kind)
end

function M.enter_worktree(path, opts)
	opts = opts or {}
	local reader = require("aero.reader")
	reader.remember()
	if not tabs.enabled() then
		if not tabs.available(path) then
			return false
		end
		local buffers = require("aero.buffers")
		buffers.remember()
		vim.t.aero_worktree = path
		vim.cmd.tcd(vim.fn.fnameescape(path))
		local kind = reader.active()
		local win = M.code_window(kind)
		if kind == "source" then
			buffers.restore(path, win)
		end
		return true
	end
	local had_dashboard = dashboard.is_open and dashboard.is_open()
	if
		opts.browse
		and had_dashboard
		and not vim.t.aero_worktree
		and not vim.t.aero_fullscreen
		and not vim.t.aero_board_path
		and not vim.t.aero_removed_workspace
		and not tabs.find(path)
	then
		if not tabs.available(path) then
			return false
		end
		-- Browsing from the sidebar should claim the initial editor tab, even when
		-- it contains a startup buffer or already has an agent panel alongside it.
		vim.t.aero_worktree = path
	end
	local created = tabs.enter(path)
	if created == nil then
		return false
	end
	if had_dashboard and config.options.dashboard.position ~= "current" and not dashboard.is_open() then
		dashboard.open()
	end
	return true
end

function M.open_session(selected, how)
	local session = require("aero.session")
	if how == "default" and panel.enabled() and config.options.dashboard.position ~= "current" then
		if not M.enter_worktree(selected.worktree) then
			return
		end
		return panel.focus(selected)
	end
	local win = M.code_window()
	if how ~= "default" then
		api.nvim_set_current_win(win)
		vim.cmd(({ vsplit = "vsplit", split = "split", tab = "tab split" })[how])
		win = api.nvim_get_current_win()
	end
	win = session.show(selected, win, how == "default")
	if win then
		dashboard.state.target = win
		api.nvim_set_current_win(win)
		if config.options.start_insert then
			session.enter(selected)
		end
	end
end

function M.open_worktree(path, opener, opts)
	if not M.enter_worktree(path, opts) then
		return
	end
	local kind = opener and "source" or require("aero.reader").active()
	local win = M.code_window(kind)
	api.nvim_set_current_win(win)
	dashboard.state.target = win
	if opener then
		opener(path)
		require("aero.buffers").remember(win)
	elseif kind == "source" then
		require("aero.buffers").restore(path, win)
	end
	return win
end

--- Browse the checkout explicitly instead of restoring a previously read document.
function M.browse_worktree(path)
	return M.open_worktree(path, function(root)
		local ok, oil = pcall(require, "oil")
		if ok and type(oil.open) == "function" then
			oil.open(root)
		else
			vim.cmd("keepalt hide edit " .. vim.fn.fnameescape(root))
		end
	end, { browse = true })
end

return M
