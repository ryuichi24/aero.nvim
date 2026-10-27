-- A shell per worktree, shown in a split at the bottom of the code window. Hiding it keeps the
-- shell running; the buffer is marked with b:aero_term = worktree path.
local config = require("aero.config")
local layout = require("aero.layout")
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
		require("aero.layout").set_buf(win, buf)
	else
		win = api.nvim_open_win(
			buf,
			false,
			{ split = "below", win = code_win, height = layout.terminal_height(worktree) }
		)
	end

	vim.wo[win].winfixheight = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	api.nvim_set_current_win(win)

	if fresh then
		local cmd, env =
			require("aero.terminal_history").prepare(worktree, config.options.terminal.cmd or { vim.o.shell })
		vim.fn.jobstart(cmd, { term = true, cwd = worktree, env = env })
		vim.bo[buf].bufhidden = "hide"
		vim.b[buf].aero_term = worktree
		require("aero.fullscreen").bind(buf)
	end

	vim.cmd.startinsert()
	layout.track(win, "terminal", worktree)
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
		layout.remember(win)
		local buf = api.nvim_win_get_buf(win)
		local worktree = vim.b[buf].aero_term
		api.nvim_win_close(win, false)
		require("aero.events").emit("terminal_closed", { worktree = worktree, win = win, buf = buf })
	end
end

--- Stop and forget the worktree's terminal (e.g. when the worktree is removed).
function M.delete(worktree)
	require("aero.terminal_history").delete(worktree)
	local buf = bufs[worktree]
	bufs[worktree] = nil

	if buf and api.nvim_buf_is_valid(buf) then
		api.nvim_buf_delete(buf, { force = true })
	end
end

--- Pick a command to copy or paste into this worktree's terminal without submitting it.
function M.history()
	local worktree = M.current_worktree()
	local commands = require("aero.terminal_history").list(worktree)

	if #commands == 0 then
		vim.notify("Aero: no terminal commands recorded (requires an interactive Bash or Zsh shell)")
		return
	end

	local items = {}

	for i = #commands, 1, -1 do
		commands[i].key = tostring(i)
		items[#items + 1] = commands[i]
	end

	local picker = require("aero.picker")

	local function paste(entry, replay)
		picker.close()
		local buf = bufs[worktree]

		if not alive(buf) then
			vim.notify("Aero: the original terminal has exited", vim.log.levels.WARN)
			return
		end

		M.open(worktree, require("aero.navigation").code_window())
		local command = entry.command

		if replay and entry.cwd then
			command = "cd -- " .. vim.fn.shellescape(entry.cwd) .. " && {\n" .. command .. "\n}"
		end

		-- Bracketed paste preserves multiline commands and replaces any unfinished input.
		api.nvim_chan_send(vim.b[buf].terminal_job_id, "\021\027[200~" .. command .. "\027[201~")
	end

	picker.open({
		title = "term history",
		width = math.floor(vim.o.columns * 0.9),
		items = function()
			return items
		end,
		preview_title = " Full command · Ctrl-d/u: scroll ",
		preview = function(entry)
			return table.concat({
				"Directory: " .. (entry.cwd or "unknown directory"),
				"Started: "
					.. (
						entry.started_at and os.date("%Y-%m-%d %H:%M:%S", math.floor(entry.started_at))
						or "unknown time"
					),
				"Exit code: " .. (entry.exit_code == nil and "unfinished/unknown" or tostring(entry.exit_code)),
				"Duration: "
					.. (
						entry.duration_seconds and string.format("%.2fs", entry.duration_seconds)
						or "unfinished/unknown"
					),
				"",
				entry.command,
			}, "\n")
		end,
		footer = " j/k: select · i: filter · Enter: paste · r: paste with cd · y: copy · q: close ",
		label = function(entry)
			local status = entry.exit_code == nil and "?" or entry.exit_code == 0 and "✓" or "✗"
			local cwd = entry.cwd or "unknown directory"

			if cwd == worktree then
				cwd = "."
			elseif vim.startswith(cwd, worktree .. "/") then
				cwd = cwd:sub(#worktree + 2)
			end

			local started = entry.started_at and os.date("%Y-%m-%d %H:%M", math.floor(entry.started_at))
				or "unknown time"
			local duration = entry.duration_seconds and string.format("%.2fs", entry.duration_seconds)
				or "unfinished/unknown"
			return string.format(
				"%s %s  [%s · %s · %s]",
				status,
				entry.command:gsub("\n", " ↵ "),
				cwd,
				started,
				duration
			)
		end,
		select = function(entry)
			paste(entry, false)
		end,
		actions = {
			r = function(entry)
				paste(entry, true)
			end,
			y = function(entry)
				picker.close()
				vim.fn.setreg("+", entry.command)
			end,
		},
	})
end

return M
