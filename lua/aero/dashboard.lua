-- The dashboard: a read-only tree buffer of workspaces > worktrees > agent sessions.
local config = require("aero.config")
local store = require("aero.store")
local git = require("aero.git")
local session = require("aero.session")
local panel = require("aero.panel")
local tabs = require("aero.tabs")
local terminal = require("aero.terminal")
local spinner = require("aero.spinner")

local M = {}

local api = vim.api
local ns = api.nvim_create_namespace("Aero")

local state = {
	buf = nil, ---@type integer?
	win = nil, ---@type integer?
	target = nil, ---@type integer? window sessions and files are opened in
	items = {}, ---@type table<integer, table> line number -> item
	worktrees = {}, ---@type table<string, {list?: Aero.Worktree[], err?: string}> workspace root -> cache
	expanded = {}, ---@type table<string, boolean> worktree path -> expanded
}

local function notify(msg, level)
	vim.notify("Aero: " .. msg, level or vim.log.levels.INFO)
end

function M.setup_highlights()
	local links = {
		AeroTitle = "Title",
		AeroWorkspace = "Directory",
		AeroWorktree = "Function",
		AeroMain = "Special",
		AeroSession = "Normal",
		AeroBusy = "DiagnosticWarn",
		AeroIdle = "DiagnosticOk",
		AeroWaiting = "DiagnosticInfo",
		AeroExited = "DiagnosticError",
		AeroStopped = "Comment",
		AeroDim = "Comment",
	}
	for group, link in pairs(links) do
		api.nvim_set_hl(0, group, { link = link, default = true })
	end
end

local status_hl = {
	busy = "AeroBusy",
	idle = "AeroIdle",
	waiting = "AeroWaiting",
	exited = "AeroExited",
	stopped = "AeroStopped",
}

local function worktrees(ws, force)
	local cache = state.worktrees[ws.root]
	if force or not cache then
		local list, err = git.list(ws.root)
		cache = { list = list, err = err }
		state.worktrees[ws.root] = cache
	end
	return cache
end

local function wt_expanded(wt, sessions)
	local e = state.expanded[wt.path]
	if e == nil then
		return #sessions > 0
	end
	return e
end

local function wt_label(wt)
	if wt.branch then
		return wt.branch
	end
	return "(detached " .. (wt.head or ""):sub(1, 7) .. ")"
end

local function summary(sessions)
	local counts, order = {}, { "waiting", "busy", "idle", "exited", "stopped" }
	for _, s in ipairs(sessions) do
		local st = session.status(s)
		counts[st] = (counts[st] or 0) + 1
	end
	local chunks = {}
	for _, st in ipairs(order) do
		if counts[st] then
			local icon = st == "busy" and spinner.frame() or config.options.icons[st]
			table.insert(chunks, { " " .. icon .. counts[st], status_hl[st] })
		end
	end
	return chunks
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local function build()
	local icons = config.options.icons
	local lines, items, marks = {}, {}, {}

	local function add(segments, item, virt)
		local text, col, hls = "", 0, {}
		for _, seg in ipairs(segments) do
			if seg[2] then
				table.insert(hls, { col, col + #seg[1], seg[2] })
			end
			text, col = text .. seg[1], col + #seg[1]
		end
		table.insert(lines, text)
		items[#lines] = item
		marks[#lines] = { hls = hls, virt = virt }
	end

	add({ { " Aero", "AeroTitle" }, { "  g? for help", "AeroDim" } })
	add({})
	if #store.data.workspaces == 0 then
		add({
			{ "  No workspaces yet. Press ", "AeroDim" },
			{ config.options.keymaps.add_workspace or "A" },
			{ " to add one.", "AeroDim" },
		})
	end

	for _, ws in ipairs(store.data.workspaces) do
		local open = ws.expanded ~= false
		add(
			{
				{ " " .. (open and icons.expanded or icons.collapsed) .. " " },
				{ ws.name, "AeroWorkspace" },
			},
			{ kind = "workspace", id = "ws:" .. ws.root, ws = ws },
			{ { " " .. vim.fn.fnamemodify(ws.root, ":~"), "AeroDim" } }
		)

		if open then
			local cache = worktrees(ws)
			if cache.err then
				add(
					{ { "     ! " .. cache.err, "AeroExited" } },
					{ kind = "workspace", id = "ws-err:" .. ws.root, ws = ws }
				)
			end
			for _, wt in ipairs(cache.list or {}) do
				local sessions = session.list(wt.path)
				local wopen = wt_expanded(wt, sessions)
				local segs = {
					{ "   " .. (wopen and icons.expanded or icons.collapsed) .. " " },
					{ wt_label(wt), "AeroWorktree" },
				}
				if wt.path == ws.root then
					table.insert(segs, { " (main)", "AeroMain" })
				end
				local virt = wopen and {} or summary(sessions)
				if wt.path ~= ws.root then
					table.insert(virt, 1, { " " .. vim.fs.basename(wt.path), "AeroDim" })
				end
				local item = { kind = "worktree", id = "wt:" .. wt.path, ws = ws, wt = wt }
				add(segs, item, virt)

				if wopen then
					if #sessions == 0 then
						add(
							{ { "       no agents — press a to start one", "AeroDim" } },
							vim.tbl_extend("force", item, { id = "wt-empty:" .. wt.path })
						)
					end
					for _, s in ipairs(sessions) do
						local st = session.status(s)
						-- what a busy ACP agent is doing, else its status
						local virt_s = { { " " .. (session.activity(s) or st), status_hl[st] } }
						if s.name ~= s.agent then
							table.insert(virt_s, { " " .. s.agent, "AeroDim" })
						end
						add({
							{ "     " },
							{ session.icon(s), status_hl[st] },
							{ " " .. s.name, "AeroSession" },
						}, { kind = "session", id = "s:" .. s.key, ws = ws, wt = wt, session = s }, virt_s)
					end
				end
			end
		end
	end
	return lines, items, marks
end

function M.render()
	local buf = state.buf
	if not (buf and api.nvim_buf_is_valid(buf)) then
		return
	end
	local win = state.win and api.nvim_win_is_valid(state.win) and api.nvim_win_get_buf(state.win) == buf and state.win
	local cur_id, cur_line
	if win then
		cur_line = api.nvim_win_get_cursor(win)[1]
		cur_id = state.items[cur_line] and state.items[cur_line].id
	end

	local lines, items, marks = build()
	state.items = items
	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].modified = false
	api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	for lnum, m in pairs(marks) do
		for _, hl in ipairs(m.hls) do
			api.nvim_buf_set_extmark(buf, ns, lnum - 1, hl[1], { end_col = hl[2], hl_group = hl[3] })
		end
		if m.virt and #m.virt > 0 then
			api.nvim_buf_set_extmark(buf, ns, lnum - 1, 0, { virt_text = m.virt, virt_text_pos = "eol" })
		end
	end

	if win then
		local target = math.min(cur_line, #lines)
		if cur_id then
			for lnum, item in pairs(items) do
				if item.id == cur_id then
					target = lnum
					break
				end
			end
		end
		api.nvim_win_set_cursor(win, { target, 0 })
	end
end

---------------------------------------------------------------------------
-- Windows
---------------------------------------------------------------------------

local function is_open()
	return state.win
		and api.nvim_win_is_valid(state.win)
		and api.nvim_win_get_tabpage(state.win) == api.nvim_get_current_tabpage()
		and state.buf
		and api.nvim_win_get_buf(state.win) == state.buf
end

-- the dashboard buffer can be shown in every tab: track this tab's window and code window
api.nvim_create_autocmd("TabEnter", {
	group = api.nvim_create_augroup("Aero.dashboard", { clear = true }),
	callback = function()
		state.win, state.target = nil, vim.t.Aero_target
		for _, w in ipairs(api.nvim_tabpage_list_wins(0)) do
			if state.buf and api.nvim_win_get_buf(w) == state.buf then
				state.win = w
			end
		end
	end,
})
api.nvim_create_autocmd("TabLeave", {
	group = "Aero.dashboard",
	callback = function()
		vim.t.Aero_target = state.target
	end,
})

local function set_win_options(win)
	local opts = {
		number = false,
		relativenumber = false,
		signcolumn = "no",
		foldcolumn = "0",
		wrap = false,
		cursorline = true,
		spell = false,
		list = false,
		winfixwidth = config.options.dashboard.position ~= "current",
	}
	for k, v in pairs(opts) do
		api.nvim_set_option_value(k, v, { win = win, scope = "local" })
	end
end

--- The window files (and, without the panel, sessions) open into: the last used window that is
--- neither the dashboard nor part of the agent panel, creating one if needed.
local function target_win()
	if config.options.dashboard.position == "current" then
		return state.win
	end
	local function usable(w)
		return w ~= state.win
			and api.nvim_win_get_config(w).relative == ""
			and not (panel.enabled() and panel.owns(w))
			and not terminal.is_term_win(w)
	end
	local tab_wins = api.nvim_tabpage_list_wins(0)
	local t = state.target
	if t and api.nvim_win_is_valid(t) and vim.tbl_contains(tab_wins, t) and usable(t) then
		return t
	end
	for _, w in ipairs(tab_wins) do
		if usable(w) then
			return w
		end
	end
	-- only the dashboard (and maybe the panel) are open: add a window between them
	local side = config.options.dashboard.position == "right" and "left" or "right"
	local w = api.nvim_open_win(api.nvim_create_buf(false, true), false, { split = side, win = state.win })
	api.nvim_win_set_width(state.win, config.options.dashboard.width)
	local pw = panel.win()
	if pw then
		api.nvim_win_set_width(pw, config.options.panel.width)
	end
	return w
end

local function get_buf()
	if state.buf and api.nvim_buf_is_valid(state.buf) then
		return state.buf
	end
	local buf = api.nvim_create_buf(false, true)
	state.buf = buf
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	pcall(api.nvim_buf_set_name, buf, "Aero://dashboard")
	M.set_keymaps(buf)
	require("aero.fullscreen").bind(buf)
	vim.bo[buf].filetype = "Aero"
	return buf
end

function M.open()
	local cur = api.nvim_get_current_win()
	if is_open() then
		api.nvim_set_current_win(state.win)
		M.render()
		return
	end
	local buf = get_buf()
	local pos = config.options.dashboard.position
	if pos == "current" then
		state.win = cur
		api.nvim_win_set_buf(cur, buf)
	else
		state.target = cur
		state.win = api.nvim_open_win(buf, true, {
			split = pos == "right" and "right" or "left",
			win = -1,
			width = config.options.dashboard.width,
		})
	end
	set_win_options(state.win)
	-- git state (and other nvim instances' changes) may have changed while the dashboard was hidden
	store.load()
	state.worktrees = {}
	M.render()
	require("aero.events").emit(
		"dashboard_opened",
		{ win = state.win, buf = state.buf, tab = api.nvim_get_current_tabpage() }
	)
end

--- Register a fullscreen window displaying the shared dashboard buffer.
function M.attach(win)
	state.win = win
	set_win_options(win)
end

function M.close()
	if require("aero.fullscreen").close("dashboard") then
		return
	end
	if not is_open() then
		return
	end
	if config.options.dashboard.position == "current" then
		local alt = vim.fn.bufnr("#")
		if alt > 0 and alt ~= state.buf and api.nvim_buf_is_valid(alt) then
			api.nvim_win_set_buf(state.win, alt)
		else
			return
		end
	elseif #api.nvim_tabpage_list_wins(0) > 1 then
		api.nvim_win_close(state.win, false)
	else
		return
	end
	local win = state.win
	state.win = nil
	require("aero.events").emit(
		"dashboard_closed",
		{ win = win, buf = state.buf, tab = api.nvim_get_current_tabpage() }
	)
end

function M.toggle()
	if is_open() and api.nvim_get_current_win() == state.win then
		M.close()
	else
		M.open()
	end
end

function M.refresh()
	store.load()
	state.worktrees = {}
	M.render()
end

-- another nvim instance may have changed the workspaces or sessions meanwhile
api.nvim_create_autocmd("FocusGained", {
	group = "Aero.dashboard",
	callback = function()
		if state.buf and api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) ~= -1 then
			store.load()
			M.render()
		end
	end,
})

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

local function current_item()
	return state.items[api.nvim_win_get_cursor(0)[1]]
end

function M.resume(session_id)
	if type(session_id) ~= "string" or vim.trim(session_id) == "" then
		notify("use :Aero resume <session-id>", vim.log.levels.WARN)
		return
	end
	local s = session.from_buf(0)
	if not s then
		local key = vim.b.aero_chat_key
		for _, candidate in ipairs(session.all()) do
			if candidate.key == key then
				s = candidate
				break
			end
		end
	end
	if not s and state.buf == api.nvim_get_current_buf() then
		local item = current_item()
		s = item and item.session
	end
	if not s then
		local win = panel.win()
		s = win and session.from_buf(api.nvim_win_get_buf(win))
	end
	local agent = s and config.options.agents[s.agent]
	if not agent or agent.type ~= "acp" then
		notify("select an ACP session in the dashboard or focus its panel first", vim.log.levels.WARN)
		return
	end
	local win = session.prepare_win(panel.win() or target_win())
	if session.start(s, win, true, vim.trim(session_id)) then
		panel.shown(s)
		api.nvim_set_current_win(win)
	end
	return s
end

--- Show `s` in a window chosen by `how` ("default" | "vsplit" | "split" | "tab") and focus it.
--- Switch to the worktree's tab (with worktree_tabs), bringing the dashboard along to new tabs.
local function enter_worktree(path)
	if not tabs.enabled() then
		return
	end
	local had_dashboard = is_open() and config.options.dashboard.position ~= "current"
	if tabs.enter(path) and had_dashboard then
		M.open()
	end
end

local function open_session(s, how)
	if how == "default" and panel.enabled() and config.options.dashboard.position ~= "current" then
		enter_worktree(s.worktree)
		return panel.focus(s)
	end
	local win = target_win()
	if how ~= "default" then
		api.nvim_set_current_win(win)
		vim.cmd(({ vsplit = "vsplit", split = "split", tab = "tab split" })[how])
		win = api.nvim_get_current_win()
	end
	win = session.show(s, win, how == "default")
	if win then
		state.target = win
		api.nvim_set_current_win(win)
		if config.options.start_insert then
			session.enter(s)
		end
	end
end

--- The session to reuse for `agent` in `worktree`: a running one if any, else the first one.
local function existing_session(worktree, agent)
	local found
	for _, s in ipairs(session.list(worktree)) do
		if s.agent == agent then
			if session.is_running(s) then
				return s
			end
			found = found or s
		end
	end
	return found
end

--- Open `agent` on the worktree under the cursor. Reuses an existing session of that agent
--- unless `new` is set.
local function start_agent(item, agent, new)
	if not (item and item.wt) then
		notify("move the cursor to a worktree first", vim.log.levels.WARN)
		return
	end
	state.expanded[item.wt.path] = true
	local s = not new and existing_session(item.wt.path, agent) or session.create(item.wt.path, agent)
	open_session(s, "default")
end

local function choose_agent(item)
	local names = vim.tbl_keys(config.options.agents)
	table.sort(names)
	vim.ui.select(names, { prompt = "New agent for " .. wt_label(item.wt) }, function(choice)
		if choice then
			start_agent(item, choice, true)
		end
	end)
end

function M.add_workspace(path)
	local function add(p)
		if not p or p == "" then
			return
		end
		local root, err = git.main_root(vim.fn.fnamemodify(vim.fn.expand(p), ":p"))
		if not root then
			notify(err, vim.log.levels.ERROR)
			return
		end
		local _, added = store.add_workspace(root)
		notify((added and "added " or "already added ") .. vim.fn.fnamemodify(root, ":~"))
		M.render()
	end
	if path then
		return add(path)
	end
	vim.ui.input({ prompt = "Add workspace (git repo): ", default = vim.fn.getcwd(), completion = "dir" }, add)
end

local function add_worktree(ws)
	vim.ui.input({ prompt = "New worktree branch (" .. ws.name .. "): " }, function(branch)
		if not branch or vim.trim(branch) == "" then
			return
		end
		branch = vim.trim(branch)
		local path = config.options.worktree_path(ws, branch)
		notify("creating worktree " .. branch .. " …")
		git.add(ws.root, branch, path, function(ok, err)
			if not ok then
				notify(err, vim.log.levels.ERROR)
				return
			end
			store.set_expanded(ws.root, true)
			state.worktrees[ws.root] = nil
			local cache = worktrees(ws)
			for _, wt in ipairs(cache.list or {}) do
				if wt.branch == branch then
					state.expanded[wt.path] = true
				end
			end
			notify("created " .. vim.fn.fnamemodify(path, ":~"))
			M.render()
		end)
	end)
end

local actions = {}

function actions.open(how)
	local item = current_item()
	if not item then
		return
	end
	if item.kind == "session" then
		open_session(item.session, how or "default")
	else
		actions.toggle()
	end
end

function actions.toggle()
	local item = current_item()
	if not item then
		return
	end
	if item.kind == "workspace" then
		store.set_expanded(item.ws.root, item.ws.expanded == false)
	elseif item.kind == "worktree" then
		state.expanded[item.wt.path] = not wt_expanded(item.wt, session.list(item.wt.path))
	end
	M.render()
end

function actions.expand()
	local item = current_item()
	if not item then
		return
	end
	if item.kind == "session" then
		return open_session(item.session, "default")
	end
	local expanded
	if item.kind == "workspace" then
		expanded = item.ws.expanded ~= false
	else
		expanded = wt_expanded(item.wt, session.list(item.wt.path))
	end
	if expanded then
		-- already open: step into the first child
		local lnum = api.nvim_win_get_cursor(0)[1]
		if state.items[lnum + 1] then
			api.nvim_win_set_cursor(0, { lnum + 1, 0 })
		end
	else
		actions.toggle()
	end
end

function actions.collapse()
	local item = current_item()
	if not item then
		return
	end
	local lnum = api.nvim_win_get_cursor(0)[1]
	local is_header = item.id:match("^ws:") or item.id:match("^wt:")
	local open = item.kind == "workspace" and item.ws.expanded ~= false
		or item.kind == "worktree" and wt_expanded(item.wt, session.list(item.wt.path))
	if is_header and open then
		return actions.toggle()
	end
	-- jump to the parent line
	local parent = item.kind == "session" and "wt:" .. item.wt.path or "ws:" .. item.ws.root
	if item.id == parent then
		parent = "ws:" .. item.ws.root
	end
	for l = lnum - 1, 1, -1 do
		if state.items[l] and state.items[l].id == parent then
			api.nvim_win_set_cursor(0, { l, 0 })
			return
		end
	end
end

function actions.add()
	local item = current_item()
	if not item then
		return M.add_workspace()
	end
	if item.kind == "workspace" then
		add_worktree(item.ws)
	else
		choose_agent(item)
	end
end

function actions.add_workspace()
	M.add_workspace()
end

function actions.delete()
	local item = current_item()
	if not item then
		return
	end
	if item.kind == "session" then
		local s = item.session
		if s.job and vim.fn.confirm("Kill running session " .. s.name .. "?", "&Yes\n&No", 2) ~= 1 then
			return
		end
		session.delete(s)
	elseif item.kind == "worktree" then
		local wt, ws = item.wt, item.ws
		if wt.path == ws.root then
			notify("refusing to remove the main worktree", vim.log.levels.WARN)
			return
		end
		local choice =
			vim.fn.confirm("Remove worktree " .. vim.fn.fnamemodify(wt.path, ":~") .. "?", "&Yes\n&Force\n&No", 3)
		if choice ~= 1 and choice ~= 2 then
			return
		end
		git.remove(ws.root, wt.path, choice == 2, function(ok, err)
			if not ok then
				notify(err .. (choice == 1 and " (use Force to remove anyway)" or ""), vim.log.levels.ERROR)
				return
			end
			session.delete_worktree(wt.path)
			terminal.delete(wt.path)
			if tabs.enabled() then
				tabs.close(wt.path)
			end
			state.worktrees[ws.root] = nil
			notify("removed " .. vim.fn.fnamemodify(wt.path, ":~"))
			M.render()
		end)
		return
	elseif item.kind == "workspace" then
		local ws = item.ws
		if vim.fn.confirm("Remove workspace " .. ws.name .. " from Aero? (files are kept)", "&Yes\n&No", 2) ~= 1 then
			return
		end
		for _, wt in ipairs(worktrees(ws).list or {}) do
			session.delete_worktree(wt.path)
		end
		store.remove_workspace(ws.root)
		state.worktrees[ws.root] = nil
	end
	M.render()
end

function actions.stop()
	local item = current_item()
	if item and item.kind == "session" then
		session.stop(item.session)
	end
end

function actions.restart()
	local item = current_item()
	if item and item.kind == "session" then
		local use_panel = panel.enabled() and config.options.dashboard.position ~= "current"
		if use_panel then
			enter_worktree(item.session.worktree)
		end
		local win = session.prepare_win(use_panel and panel.open() or target_win())
		if session.start(item.session, win, true) then
			if use_panel then
				panel.shown(item.session)
			else
				state.target = win
			end
		end
	end
end

function actions.refresh()
	M.refresh()
end

local function item_dir(item)
	return item and (item.wt and item.wt.path or item.ws and item.ws.root)
end

function actions.cd()
	local dir = item_dir(current_item())
	if dir then
		vim.cmd.tcd(vim.fn.fnameescape(dir))
		notify("tcd " .. vim.fn.fnamemodify(dir, ":~"))
	end
end

function M.open_worktree(dir, opener)
	enter_worktree(dir)
	local win = target_win()
	api.nvim_set_current_win(win)
	state.target = win
	if opener then
		opener(dir)
	else
		vim.cmd.edit(vim.fn.fnameescape(dir))
	end
	return win
end

function actions.edit()
	local dir = item_dir(current_item())
	if dir then
		M.open_worktree(dir)
	end
end

function actions.terminal()
	local dir = item_dir(current_item())
	if dir then
		enter_worktree(dir)
		terminal.open(dir, target_win())
	end
end

--- Toggle the current tab's worktree terminal below the code window.
function M.toggle_terminal()
	if terminal.win() then
		return terminal.hide()
	end
	terminal.open(terminal.current_worktree(), target_win())
end

local function jump_workspace(dir)
	local lnum = api.nvim_win_get_cursor(0)[1]
	local l = lnum + dir
	while l >= 1 and l <= api.nvim_buf_line_count(0) do
		local item = state.items[l]
		if item and item.id:match("^ws:") then
			api.nvim_win_set_cursor(0, { l, 0 })
			return
		end
		l = l + dir
	end
end

function actions.next_workspace()
	jump_workspace(1)
end

function actions.prev_workspace()
	jump_workspace(-1)
end

function actions.close()
	M.close()
end

local descriptions = {
	open = "open session / toggle node",
	expand = "expand node / open session",
	collapse = "collapse node / go to parent",
	toggle = "toggle node",
	open_vsplit = "open session in vsplit",
	open_split = "open session in split",
	open_tab = "open session in tab",
	add = "add: worktree (on workspace) / new agent session (on worktree)",
	add_workspace = "add workspace",
	delete = "delete session / worktree / workspace",
	stop = "stop session",
	restart = "restart session (resume)",
	refresh = "refresh git worktrees",
	cd = ":tcd to worktree",
	edit = "open worktree directory",
	terminal = "open worktree terminal",
	next_workspace = "next workspace",
	prev_workspace = "previous workspace",
	close = "close dashboard",
	help = "show this help",
}

function actions.help()
	local lines = {}
	local keys = config.options.keymaps
	local names = vim.tbl_keys(descriptions)
	table.sort(names)
	for _, name in ipairs(names) do
		if keys[name] then
			table.insert(lines, ("  %-8s %s"):format(keys[name], descriptions[name]))
		end
	end
	if config.options.fullscreen_key then
		table.insert(lines, ("  %-8s toggle fullscreen"):format(config.options.fullscreen_key))
	end
	local agents = vim.tbl_keys(config.options.agents)
	table.sort(agents)
	for _, name in ipairs(agents) do
		local key = config.options.agents[name].key
		if key then
			table.insert(lines, ("  %-8s open %s on worktree"):format(key, name))
		end
	end
	local width = 0
	for _, l in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(l) + 2)
	end
	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = #lines,
		row = math.floor((vim.o.lines - #lines) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " Aero ",
	})
	for _, key in ipairs({ "q", "<Esc>", "g?" }) do
		vim.keymap.set("n", key, function()
			api.nvim_win_close(win, true)
		end, { buffer = buf, nowait = true })
	end
end

function M.set_keymaps(buf)
	local keys = config.options.keymaps
	local function map(lhs, fn, desc)
		if lhs then
			vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Aero: " .. desc })
		end
	end
	for name, fn in pairs(actions) do
		if name ~= "open" then
			map(keys[name], fn, descriptions[name] or name)
		end
	end
	map(keys.open, function()
		actions.open("default")
	end, descriptions.open)
	map(keys.open_vsplit, function()
		actions.open("vsplit")
	end, descriptions.open_vsplit)
	map(keys.open_split, function()
		actions.open("split")
	end, descriptions.open_split)
	map(keys.open_tab, function()
		actions.open("tab")
	end, descriptions.open_tab)
	for name, agent in pairs(config.options.agents) do
		map(agent.key, function()
			start_agent(current_item(), name)
		end, "open " .. name)
	end
end

---------------------------------------------------------------------------
-- Pickers
---------------------------------------------------------------------------

--- Pick any session across all workspaces with vim.ui.select and open it in the panel
--- (or the current window when the panel is disabled).
function M.pick()
	local choices = {}
	for _, ws in ipairs(store.data.workspaces) do
		for _, wt in ipairs(worktrees(ws).list or {}) do
			for _, s in ipairs(session.list(wt.path)) do
				table.insert(choices, { ws = ws, wt = wt, session = s })
			end
		end
	end
	if #choices == 0 then
		notify("no sessions")
		return
	end
	vim.ui.select(choices, {
		prompt = "Agent session",
		format_item = function(c)
			local what = session.activity(c.session)
			return ("%s %s / %s / %s%s"):format(
				session.icon(c.session),
				c.ws.name,
				wt_label(c.wt),
				c.session.name,
				what and "  " .. what or ""
			)
		end,
	}, function(c)
		if c and panel.enabled() then
			enter_worktree(c.session.worktree)
			panel.focus(c.session)
		elseif c then
			local win = api.nvim_get_current_win()
			if win == state.win then
				win = target_win()
			end
			win = session.show(c.session, win)
			if win then
				api.nvim_set_current_win(win)
				if config.options.start_insert then
					session.enter(c.session)
				end
			end
		end
	end)
end

session.on_change(function()
	if state.buf and api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) ~= -1 then
		M.render()
	end
end)

-- spin busy sessions' icons and keep their activity current
spinner.on_frame(function()
	local busy = vim.iter(session.all()):any(function(s)
		return session.status(s) == "busy"
	end)
	if busy and state.buf and api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) ~= -1 then
		M.render()
	end
	return busy
end)

return M
