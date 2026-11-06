-- Worktree-local terminal tabs and split shells. Hidden panes keep running;
-- each terminal buffer is marked with b:aero_term = worktree path.
local config = require("aero.config")
local layout = require("aero.layout")
local M = {}
local api = vim.api

---@type table<string, integer> worktree path -> terminal buffer
local bufs = {}
local workspaces = {}

local function workspace(path)
	workspaces[path] = workspaces[path] or { tabs = { {} }, active = 1 }
	return workspaces[path]
end

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
local function open_shell(worktree, code_win, target)
	local win = target or M.win()
	local buf = bufs[worktree]
	local fresh = not alive(buf)

	if fresh and not (buf and api.nvim_buf_is_valid(buf) and vim.bo[buf].buftype == "nofile") then
		local old = buf
		buf = api.nvim_create_buf(false, true)
		bufs[worktree] = buf

		if win then
			layout.set_buf(win, buf)
		end

		if old and api.nvim_buf_is_valid(old) then
			api.nvim_buf_delete(old, { force = true })
		end
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

local function capture(node)
	if node[1] == "leaf" then
		local buf = api.nvim_win_get_buf(node[2])
		return vim.b[buf].aero_term and { "leaf", buf } or nil
	end

	local children = {}

	for _, child in ipairs(node[2]) do
		local saved = capture(child)

		if saved then
			children[#children + 1] = saved
		end
	end

	return #children == 1 and children[1] or #children > 1 and { node[1], children } or nil
end

local function header(path)
	local state = workspace(path)
	local labels = {}

	for i in ipairs(state.tabs) do
		labels[#labels + 1] = i == state.active and ("[" .. i .. "]") or tostring(i)
	end

	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if M.is_term_win(win) then
			vim.wo[win].winbar = " Term " .. table.concat(labels, "  ")
		end
	end
end

local function restore(node, win, path)
	if node[1] == "leaf" then
		bufs[path] = node[2]
		layout.set_buf(win, node[2])
		open_shell(path, win, win)
		return
	end

	local windows = { win }

	for i = 2, #node[2] do
		windows[i] = api.nvim_open_win(api.nvim_create_buf(false, true), false, {
			split = node[1] == "row" and "right" or "below",
			win = windows[i - 1],
		})
	end

	for i, child in ipairs(node[2]) do
		restore(child, windows[i], path)
	end
end

--- Show the active terminal tab, restoring its split panes.
function M.open(path, code_win)
	local state = workspace(path)
	local tab = state.tabs[state.active]
	local win = M.win()

	if win and vim.b[api.nvim_win_get_buf(win)].aero_term == path then
		local current = api.nvim_get_current_win()

		if M.is_term_win(current) then
			win = current
		end

		api.nvim_set_current_win(win)
		bufs[path] = api.nvim_win_get_buf(win)
		vim.cmd.startinsert()
		return win
	end

	if win then
		M.hide()
	end

	bufs[path] = tab.buf
	win = open_shell(path, code_win)

	if tab.tree then
		restore(tab.tree, win, path)
	end

	tab.buf = bufs[path]
	header(path)
	return api.nvim_get_current_win()
end

--- Hide the terminal window in this tab (the shell keeps running).
function M.hide()
	if require("aero.fullscreen").close("terminal") then
		return
	end

	local win = M.win()

	if win then
		local path = vim.b[api.nvim_win_get_buf(win)].aero_term
		local state = workspace(path)
		local tab = state.tabs[state.active]
		tab.tree = capture(vim.fn.winlayout())
		tab.buf = bufs[path]
		layout.remember(win)

		for _, pane in ipairs(api.nvim_tabpage_list_wins(0)) do
			if M.is_term_win(pane) and #api.nvim_tabpage_list_wins(0) > 1 then
				local buf = api.nvim_win_get_buf(pane)
				api.nvim_win_close(pane, false)
				require("aero.events").emit("terminal_closed", { worktree = path, win = pane, buf = buf })
			end
		end
	end
end

--- Manage worktree-local terminal tabs and independent split shells.
function M.action(action)
	local path = M.current_worktree()
	local state = workspace(path)
	local code_win = require("aero.navigation").code_window()

	if action == "split" or action == "vsplit" then
		local parent = M.open(path, code_win)
		local buf = api.nvim_create_buf(false, true)
		local win = api.nvim_open_win(buf, true, { split = action == "vsplit" and "right" or "below", win = parent })
		vim.b[buf].aero_term = path
		bufs[path] = buf
		open_shell(path, win, win)
		header(path)
		return
	end

	M.hide()

	if action == "new" then
		state.tabs[#state.tabs + 1] = {}
		state.active = #state.tabs
	elseif action == "next" or action == "prev" then
		state.active = (state.active - 1 + (action == "next" and 1 or -1)) % #state.tabs + 1
	elseif action == "close" then
		local tab = table.remove(state.tabs, state.active)
		local function dispose(node)
			if not node then
				return
			end

			if node[1] == "leaf" then
				if api.nvim_buf_is_valid(node[2]) then
					api.nvim_buf_delete(node[2], { force = true })
				end
			else
				for _, child in ipairs(node[2]) do
					dispose(child)
				end
			end
		end
		dispose(tab.tree or (tab.buf and { "leaf", tab.buf }))
		state.active = math.max(1, math.min(state.active, #state.tabs))

		if #state.tabs == 0 then
			workspaces[path] = nil
			bufs[path] = nil
			return
		end
	end

	return M.open(path, code_win)
end

--- Stop and forget the worktree's terminal (e.g. when the worktree is removed).
function M.delete(worktree)
	require("aero.terminal_history").delete(worktree)
	local buf = bufs[worktree]
	bufs[worktree] = nil
	workspaces[worktree] = nil

	for _, candidate in ipairs(api.nvim_list_bufs()) do
		if vim.b[candidate].aero_term == worktree then
			api.nvim_buf_delete(candidate, { force = true })
		end
	end

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
		M.open(worktree, require("aero.navigation").code_window())
		local buf = bufs[worktree]

		if not alive(buf) then
			vim.notify("Aero: the original terminal has exited", vim.log.levels.WARN)
			return
		end

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
