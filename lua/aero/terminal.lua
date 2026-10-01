-- A shell per worktree, shown in a split at the bottom of the code window. Hiding it keeps the
-- shell running; the buffer is marked with b:aero_term = worktree path.
local config = require("aero.config")

local M = {}

local api = vim.api

---@type table<string, integer> worktree path -> terminal buffer
local bufs = {}

--- The worktree the current tab works on.
function M.current_worktree()
	return vim.t.aero_worktree or vim.fn.getcwd()
end

local function alive(buf)
	if not (buf and api.nvim_buf_is_valid(buf)) then
		return false
	end
	local job = vim.b[buf].terminal_job_id
	return job ~= nil and vim.fn.jobwait({ job }, 0)[1] == -1
end

--- This tab's terminal window, if one is shown.
function M.win()
	for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
		if vim.b[api.nvim_win_get_buf(w)].aero_term then
			return w
		end
	end
end

function M.is_term_win(win)
	return vim.b[api.nvim_win_get_buf(win)].aero_term ~= nil
end

--- Show the worktree's terminal below `code_win` (starting a shell if needed) and focus it.
function M.open(worktree, code_win)
	local win = M.win()
	local buf = bufs[worktree]
	if win and api.nvim_win_get_buf(win) == buf and alive(buf) then
		api.nvim_set_current_win(win)
		vim.cmd.startinsert()
		return win
	end
	local fresh = not alive(buf)
	if fresh then
		if buf and api.nvim_buf_is_valid(buf) then
			api.nvim_buf_delete(buf, { force = true })
		end
		buf = api.nvim_create_buf(false, true)
		bufs[worktree] = buf
	end
	if win then
		-- another worktree's terminal is showing: reuse its window
		api.nvim_win_set_buf(win, buf)
	else
		win =
			api.nvim_open_win(buf, false, { split = "below", win = code_win, height = config.options.terminal.height })
	end
	vim.wo[win].winfixheight = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	api.nvim_set_current_win(win)
	if fresh then
		vim.fn.jobstart(config.options.terminal.cmd or { vim.o.shell }, { term = true, cwd = worktree })
		vim.bo[buf].bufhidden = "hide"
		vim.b[buf].aero_term = worktree
		require("aero.fullscreen").bind(buf)
	end
	vim.cmd.startinsert()
	require("aero.events").emit("terminal_opened", { worktree = worktree, win = win, buf = buf, fresh = fresh })
	return win
end

--- Hide the terminal window in this tab (the shell keeps running).
function M.hide()
	if require("aero.fullscreen").close("terminal") then
		return
	end
	local win = M.win()
	if win and #api.nvim_tabpage_list_wins(0) > 1 then
		local buf = api.nvim_win_get_buf(win)
		local worktree = vim.b[buf].aero_term
		api.nvim_win_close(win, false)
		require("aero.events").emit("terminal_closed", { worktree = worktree, win = win, buf = buf })
	end
end

--- Stop and forget the worktree's terminal (e.g. when the worktree is removed).
function M.delete(worktree)
	local buf = bufs[worktree]
	bufs[worktree] = nil
	if buf and api.nvim_buf_is_valid(buf) then
		api.nvim_buf_delete(buf, { force = true })
	end
end

return M
