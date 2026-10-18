-- The dashboard: a read-only tree buffer of workspaces > worktrees > agent sessions.
local config = require("aero.config")
local store = require("aero.store")
local git = require("aero.git")
local session = require("aero.session")
local panel = require("aero.panel")
local tabs = require("aero.tabs")
local terminal = require("aero.terminal")
local spinner = require("aero.spinner")
local reports = require("aero.reports")
local navigation = require("aero.navigation")

local M = {}

local api = vim.api

local state = {
	buf = nil, ---@type integer?
	win = nil, ---@type integer?
	target = nil, ---@type integer? window sessions and files are opened in
	items = {}, ---@type table<integer, table> line number -> item
	worktrees = {}, ---@type table<string, {list?: Aero.Worktree[], err?: string}> workspace root -> cache
	expanded = {}, ---@type table<string, boolean> worktree path -> expanded
	reports_expanded = {}, -- worktree path -> report section expanded
	reference_expanded = {}, -- worktree path -> reference section expanded
	reference_folders_expanded = {}, -- reference directory path -> expanded
	exports_expanded = {}, -- worktree path -> exported logs section expanded
	boards_expanded = {}, -- workspace root -> board section expanded
	bindings = {}, -- mappings installed by Aero, replaced when setup runs again
	pulling = {}, -- worktree path -> in-flight pull
}

local function notify(msg, level)
	vim.notify("Aero: " .. msg, level or vim.log.levels.INFO)
end

function M.setup_highlights()
	local links = {
		AeroTitle = "Title",
		AeroWorkspace = "Directory",
		AeroWorktree = "Function",
		AeroBranch = "Special",
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
		if list then
			cache.checking = true
			git.remote_status(ws.root, function(statuses, fetch_err)
				if state.worktrees[ws.root] ~= cache then
					return
				end
				cache.checking = false
				cache.statuses, cache.fetch_err = statuses, fetch_err
				M.render()
			end)
		end
	end
	return cache
end

-- Loading is explicit: rendering never initiates Git listing or remote requests.
local function load_worktrees()
	for _, workspace in ipairs(store.data.workspaces) do
		if workspace.expanded ~= false then
			worktrees(workspace)
		end
	end
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

local animation_snapshot

local function reference_children(entries)
	for _, entry in ipairs(entries) do
		if entry.kind == "directory" then
			entry.expanded = state.reference_folders_expanded[entry.path] == true
			if entry.expanded then
				entry.children = {}
				local scan, err = vim.uv.fs_scandir(entry.path)
				entry.err = err
				if scan then
					while true do
						local name, kind = vim.uv.fs_scandir_next(scan)
						if not name then break end
						table.insert(entry.children, { name = name, kind = kind, path = vim.fs.joinpath(entry.path, name) })
					end
					table.sort(entry.children, function(a, b) return a.name < b.name end)
					reference_children(entry.children)
				end
			end
		end
	end
end

local function build()
	local snapshot = { icons = config.options.icons, add_key = config.options.keymaps.add_workspace, workspaces = {} }
	for _, ws in ipairs(store.data.workspaces) do
		local workspace =
			{ ws = ws, display_path = " " .. vim.fn.fnamemodify(ws.root, ":~"), worktrees = {}, boards = {} }
		table.insert(snapshot.workspaces, workspace)
		if ws.expanded ~= false then
			workspace.cache = state.worktrees[ws.root] or { list = {} }
			for _, wt in ipairs(workspace.cache.list or {}) do
				local sessions = session.list(wt.path)
				local tree = {
					wt = wt,
					basename = vim.fs.basename(wt.path),
					expanded = wt_expanded(wt, sessions),
					summary = summary(sessions),
					sessions = {},
					exports = {},
					reports = {},
				}
				table.insert(workspace.worktrees, tree)
				if tree.expanded then
					for _, selected in ipairs(sessions) do
						table.insert(
							tree.sessions,
							{
								session = selected,
								status = session.status(selected),
								icon = session.icon(selected),
								activity = session.activity(selected),
								usage = require("aero.acp.usage").summary(selected.chat),
								assignment = require("aero.tasks.status").label(selected),
							}
						)
					end
					tree.exports = require("aero.exports").list(wt.path)
					tree.exports_open = state.exports_expanded[wt.path] ~= false
					tree.reports, tree.report_err = reports.list(wt.path, ws)
					tree.reports_open = state.reports_expanded[wt.path] ~= false
					tree.references, tree.reference_err = require("aero.reference").list(wt.path)
					tree.reference_open = state.reference_expanded[wt.path] ~= false
					if tree.reference_open then reference_children(tree.references) end
				end
			end
			local boards
			boards, workspace.board_errors = require("aero.tasks").list(ws)
			workspace.boards_open = state.boards_expanded[ws.root] ~= false
			workspace.removed_count = workspace.boards_open and #require("aero.tasks").list_removed(ws) or 0
			for _, board in ipairs(boards) do
				table.insert(
					workspace.boards,
					{
						board = board,
						label = tostring((board.metadata or {}).title or vim.fs.basename(vim.fs.dirname(board.path))):gsub(
							"[%c]",
							" "
						),
					}
				)
			end
		end
	end
	animation_snapshot = snapshot
	return require("aero.dashboard.model").build(snapshot)
end

-- Animation must not rescan the filesystem or invoke task metadata subprocesses.
local function animate()
	if not animation_snapshot then
		return
	end
	for _, workspace in ipairs(animation_snapshot.workspaces) do
		for _, tree in ipairs(workspace.worktrees) do
			tree.summary = summary(session.list(tree.wt.path))
			for _, item in ipairs(tree.sessions) do
				item.status = session.status(item.session)
				item.icon = session.icon(item.session)
				item.activity = session.activity(item.session)
				item.usage = require("aero.acp.usage").summary(item.session.chat)
			end
		end
	end
	local lines, items, marks = require("aero.dashboard.model").build(animation_snapshot)
	require("aero.dashboard.view").render(state, lines, items, marks)
end

--- Collapse all existing sidebar nodes of a type, including hidden descendants.
function M.collapse(kind)
	kind = kind or "all"
	if kind == "context" then kind = "reference" end -- legacy command alias
	local valid = { all = true, workspaces = true, worktrees = true, reports = true, exports = true, boards = true, reference = true }
	if not valid[kind] then
		notify("use :Aero collapse [all|workspaces|worktrees|reports|exports|boards|reference]", vim.log.levels.WARN)
		return
	end
	if kind == "all" or kind == "reference" then state.reference_folders_expanded = {} end
	for _, ws in ipairs(store.data.workspaces) do
		if kind == "all" or kind == "boards" then
			state.boards_expanded[ws.root] = false
		end
		if kind == "all" or kind == "worktrees" or kind == "reports" or kind == "exports" or kind == "reference" then
			local cache = state.worktrees[ws.root]
			local list = cache and cache.list or git.list(ws.root)
			for _, wt in ipairs(list or {}) do
				if kind == "all" or kind == "worktrees" then
					state.expanded[wt.path] = false
				end
				if kind == "all" or kind == "reports" then
					state.reports_expanded[wt.path] = false
				end
				if kind == "all" or kind == "reference" then
					state.reference_expanded[wt.path] = false
				end
				if kind == "all" or kind == "exports" then
					state.exports_expanded[wt.path] = false
				end
			end
		end
		if kind == "all" or kind == "workspaces" then
			store.set_expanded(ws.root, false)
		end
	end
	M.render()
end

function M.render()
	local buf = state.buf
	if not (buf and api.nvim_buf_is_valid(buf)) then
		return
	end
	local lines, items, marks = build()
	require("aero.dashboard.view").render(state, lines, items, marks)
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
	return navigation.code_window()
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
	local width = require("aero.layout").dashboard_width()
	if pos == "current" then
		state.win = cur
		api.nvim_win_set_buf(cur, buf)
	else
		state.target = cur
		state.win = api.nvim_open_win(buf, true, {
			split = pos == "right" and "right" or "left",
			win = -1,
			width = width,
		})
		-- Focusing a new window can apply 'winwidth'; restore the requested sidebar size.
		api.nvim_win_set_width(state.win, width)
	end
	set_win_options(state.win)
	if pos ~= "current" then
		require("aero.layout").track(state.win, "dashboard", nil, width)
		require("aero.layout").rebalance()
	end
	-- git state (and other nvim instances' changes) may have changed while the dashboard was hidden
	store.load()
	state.worktrees = {}
	load_worktrees()
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
	require("aero.layout").remember(state.win)
	if config.options.dashboard.position == "current" then
		local alt = api.nvim_win_call(state.win, function()
			return vim.fn.bufnr("#")
		end)
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
	if is_open() then
		M.close()
	else
		M.open()
	end
end

function M.refresh()
	store.load()
	state.worktrees = {}
	load_worktrees()
	M.render()
end

-- another nvim instance may have changed the workspaces or sessions meanwhile
api.nvim_create_autocmd("FocusGained", {
	group = "Aero.dashboard",
	callback = function()
		if state.buf and api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) ~= -1 then
			store.load()
			load_worktrees()
			M.render()
		end
	end,
})

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Source boards can be edited directly without opening their derived view.
api.nvim_create_autocmd("BufWritePost", {
	group = "Aero.dashboard",
	pattern = "*.md",
	callback = function(event)
		if not state.buf or not api.nvim_buf_is_valid(state.buf) or vim.fn.bufwinid(state.buf) == -1 then
			return
		end
		for _, ws in ipairs(store.data.workspaces) do
			local directory = require("aero.tasks").directory(ws)
			if directory and require("aero.storage").inside(event.file, directory) then
				vim.schedule(M.render)
				return
			end
		end
	end,
})

local function current_item()
	return state.items[api.nvim_win_get_cursor(0)[1]]
end

require("aero.session_target").set_dashboard_selection(function()
	local selected = api.nvim_get_current_buf() == state.buf
	return selected, selected and current_item() or nil
end)
navigation.set_dashboard({ state = state, is_open = is_open, open = M.open })

function M.selected_workspace()
	local item = api.nvim_get_current_buf() == state.buf and current_item()
	return item and item.ws or nil
end

function M.selected_worktree()
	local item = api.nvim_get_current_buf() == state.buf and current_item()
	return item and item.wt and item.wt.path or nil
end

function M.code_window()
	return target_win() or api.nvim_get_current_win()
end

--- Attach a report to the focused session, dashboard selection, or this worktree's agent.
function M.report()
	local s = session.from_buf(0)
	local key = vim.b.aero_chat_key
	if not s and key then
		for _, candidate in ipairs(session.all()) do
			if candidate.key == key then
				s = candidate
				break
			end
		end
	end
	local item = api.nvim_get_current_buf() == state.buf and current_item() or nil
	s = s or item and item.session
	local path = s and s.worktree or item and item.wt and item.wt.path
	if item and not path then
		notify("select a worktree or agent session first", vim.log.levels.WARN)
		return
	end
	path = path or vim.t.aero_worktree or vim.fn.getcwd()
	return reports.choose_session(path, s or panel.current_session(), item and item.ws)
end

--- Cancel the focused ACP session, dashboard selection, or this tab's panel session.
function M.cancel()
	return require("aero.commands").cancel()
end

function M.resume(session_id)
	return require("aero.commands").resume(session_id)
end

--- Resolve the focused or dashboard-selected session without starting it.
function M.viewed_session()
	return require("aero.session_target").resolve("viewed")
end

--- Show agent-reported usage for the focused/selected session without starting it.
function M.usage()
	return require("aero.commands").usage()
end

--- Show `s` in a window chosen by `how` ("default" | "vsplit" | "split" | "tab") and focus it.
--- Switch to the worktree's tab (with worktree_tabs), bringing the dashboard along to new tabs.
local function enter_worktree(path)
	return navigation.enter_worktree(path)
end

local function open_session(s, how)
	return navigation.open_session(s, how)
end

--- Start a fresh session of `agent` on the worktree under the cursor.
local function start_agent(item, agent)
	if not (item and item.wt) then
		notify("move the cursor to a worktree first", vim.log.levels.WARN)
		return
	end
	local function create(name)
		local s, err = session.create(item.wt.path, agent, name)
		if not s then
			notify(err, vim.log.levels.WARN)
			return
		end
		state.expanded[item.wt.path] = true
		open_session(s, "default")
	end
	if not config.options.prompt_session_name then
		return create()
	end
	require("aero.input").input({ prompt = "New session name: ", default = agent }, function(name)
		if not name or vim.trim(name) == "" then
			return
		end
		name = vim.trim(name)
		if name:find("%c") then
			notify("use a session name without control characters", vim.log.levels.WARN)
			return
		end
		create(name)
	end)
end

local function choose_agent(item)
	local names = vim.tbl_keys(config.options.agents)
	table.sort(names)
	table.insert(names, 1, "default")
	vim.ui.select(names, {
		prompt = "New agent for " .. wt_label(item.wt),
		format_item = function(name)
			return name == "default" and ("default (" .. config.options.default_agent .. ")") or name
		end,
	}, function(choice, index)
		if choice then
			if index == 1 or (index == nil and choice == "default") then
				choice = config.options.default_agent
			end
			start_agent(item, choice)
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
		load_worktrees()
		M.render()
	end
	if path then
		return add(path)
	end
	vim.ui.input({ prompt = "Add workspace (git repo): ", default = vim.fn.getcwd(), completion = "dir" }, add)
end

local function add_worktree(ws)
	local function create(branch, remote)
		if not branch or vim.trim(branch) == "" then
			return
		end
		branch = vim.trim(branch)
		local default_path = config.options.worktree_path(ws, branch)
		vim.ui.input({ prompt = "Worktree name: ", default = vim.fs.basename(default_path) }, function(name)
			if not name or vim.trim(name) == "" then
				return
			end
			name = vim.trim(name)
			if name == "." or name == ".." or name:find("/", 1, true) then
				return notify("Worktree name must be a single directory name", vim.log.levels.WARN)
			end
			local path = vim.fs.joinpath(vim.fs.dirname(default_path), name)
			notify("creating worktree " .. name .. " (" .. branch .. ") …")
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
			end, remote)
		end)
	end
	vim.ui.select({ "Create a new branch", "Check out an existing branch", "Check out a remote branch" }, {
		prompt = "Add worktree (" .. ws.name .. "):",
	}, function(choice)
		if choice == "Create a new branch" then
			vim.ui.input({ prompt = "New worktree branch (" .. ws.name .. "): " }, create)
		elseif choice == "Check out an existing branch" then
			git.branches(ws.root, function(branches, err)
				if not branches then
					return notify(err, vim.log.levels.ERROR)
				end
				local trees, list_err = git.list(ws.root)
				if not trees then
					return notify(list_err, vim.log.levels.ERROR)
				end
				local occupied = {}
				for _, wt in ipairs(trees) do
					if wt.branch then
						occupied[wt.branch] = true
					end
				end
				local available = {}
				for _, branch in ipairs(branches) do
					if not branch.remote and not occupied[branch.name] then
						table.insert(available, branch.name)
					end
				end
				if #available == 0 then
					return notify("No available local branches; create a new branch or choose a remote branch", vim.log.levels.WARN)
				end
				vim.ui.select(available, { prompt = "Existing branch:" }, function(branch)
					create(branch)
				end)
			end)
		elseif choice == "Check out a remote branch" then
			git.remote_branches(ws.root, function(branches, err)
				if not branches then
					return notify(err, vim.log.levels.ERROR)
				end
				if #branches == 0 then
					return notify("No remote branches found; fetch the repository first", vim.log.levels.WARN)
				end
				vim.ui.select(branches, { prompt = "Remote branch:" }, function(remote)
					if remote then
						create(remote:match("^[^/]+/(.+)$"), remote)
					end
				end)
			end)
		end
	end)
end

local actions = {}

local function open_report(item, how)
	if not enter_worktree(item.wt.path) then
		return
	end
	local kind = item.kind == "export" and "exports" or item.kind == "reference_item" and "references" or "reports"
	local win = navigation.code_window(kind)
	api.nvim_set_current_win(win)
	if how and how ~= "default" then
		vim.cmd(({ vsplit = "vsplit", split = "split", tab = "tab split" })[how])
	end
	vim.cmd.edit(vim.fn.fnameescape(item.report.path))
	state.target = api.nvim_get_current_win()
	require("aero.buffers").remember(state.target)
end

local function new_report(item)
	reports.create(item.wt.path, item.ws, function(report)
		state.expanded[item.wt.path], state.reports_expanded[item.wt.path] = true, true
		M.render()
		open_report(vim.tbl_extend("force", item, { report = report }))
	end)
end

function actions.open(how)
	local item = current_item()
	if not item then
		return
	end
	if item.kind == "board" then
		require("aero.tasks.view").open(item.ws, item.board.path)
	elseif item.kind == "board_new" then
		require("aero.tasks.ui").new_board(item.ws)
	elseif item.kind == "tickets_removed" then
		require("aero.tasks.ui").removed(item.ws)
	elseif item.kind == "session" then
		open_session(item.session, how or "default")
	elseif item.kind == "report" or item.kind == "export" then
		open_report(item, how)
	elseif item.kind == "reference_item" then
		if item.reference.kind == "directory" then
			actions.toggle()
		else
			open_report(vim.tbl_extend("force", item, { report = item.reference }), how)
		end
	elseif item.kind == "reference_new" then
		require("aero.reference").open(item.wt.path)
	elseif item.kind == "report_new" then
		new_report(item)
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
		load_worktrees()
	elseif item.kind == "worktree" then
		state.expanded[item.wt.path] = not wt_expanded(item.wt, session.list(item.wt.path))
	elseif item.kind == "exports" then
		state.exports_expanded[item.wt.path] = state.exports_expanded[item.wt.path] == false
	elseif item.kind == "reports" then
		state.reports_expanded[item.wt.path] = state.reports_expanded[item.wt.path] == false
	elseif item.kind == "reference" then
		state.reference_expanded[item.wt.path] = state.reference_expanded[item.wt.path] == false
	elseif item.kind == "reference_item" and item.reference.kind == "directory" then
		state.reference_folders_expanded[item.reference.path] = not state.reference_folders_expanded[item.reference.path]
	elseif item.kind == "boards" then
		state.boards_expanded[item.ws.root] = state.boards_expanded[item.ws.root] == false
	end
	M.render()
end

function actions.expand()
	local item = current_item()
	if not item then
		return
	end
	if
		item.kind == "session"
		or item.kind == "export"
		or item.kind == "report"
		or item.kind == "report_new"
		or item.kind == "reference_item" and item.reference.kind ~= "directory"
		or item.kind == "reference_new"
		or item.kind == "board"
		or item.kind == "board_new"
		or item.kind == "tickets_removed"
	then
		return actions.open("default")
	end
	local expanded
	if item.kind == "workspace" then
		expanded = item.ws.expanded ~= false
	elseif item.kind == "exports" then
		expanded = state.exports_expanded[item.wt.path] ~= false
	elseif item.kind == "reports" then
		expanded = state.reports_expanded[item.wt.path] ~= false
	elseif item.kind == "reference" then
		expanded = state.reference_expanded[item.wt.path] ~= false
	elseif item.kind == "reference_item" and item.reference.kind == "directory" then
		expanded = state.reference_folders_expanded[item.reference.path] == true
	elseif item.kind == "boards" then
		expanded = state.boards_expanded[item.ws.root] ~= false
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
	local is_header = item.id:match("^ws:")
		or item.id:match("^wt:")
		or item.kind == "reports"
		or item.kind == "reference"
		or item.kind == "reference_item" and item.reference.kind == "directory"
		or item.kind == "boards"
		or item.kind == "exports"
	local open = item.kind == "workspace" and item.ws.expanded ~= false
		or item.kind == "worktree" and wt_expanded(item.wt, session.list(item.wt.path))
		or item.kind == "reports" and state.reports_expanded[item.wt.path] ~= false
		or item.kind == "reference" and state.reference_expanded[item.wt.path] ~= false
		or item.kind == "reference_item" and state.reference_folders_expanded[item.reference.path] == true
		or item.kind == "exports" and state.exports_expanded[item.wt.path] ~= false
		or item.kind == "boards" and state.boards_expanded[item.ws.root] ~= false
	if is_header and open then
		return actions.toggle()
	end
	-- jump to the parent line
	local parent = (item.kind == "board" or item.kind == "board_new" or item.kind == "tickets_removed")
			and "boards:" .. item.ws.root
		or item.kind == "export" and "exports:" .. item.wt.path
		or item.kind == "exports" and "wt:" .. item.wt.path
		or (item.kind == "report" or item.kind == "report_new") and "reports:" .. item.wt.path
		or item.kind == "reference_item" and item.parent
		or (item.kind == "reference_item" or item.kind == "reference_new") and "reference:" .. item.wt.path
		or item.kind == "reference" and "wt:" .. item.wt.path
		or (item.kind == "session" or item.kind == "reports") and "wt:" .. item.wt.path
		or "ws:" .. item.ws.root
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
	if item.kind == "boards" or item.kind == "board" or item.kind == "board_new" or item.kind == "tickets_removed" then
		require("aero.tasks.ui").new_board(item.ws)
	elseif item.kind == "workspace" then
		add_worktree(item.ws)
	elseif item.kind == "reports" or item.kind == "report" or item.kind == "report_new" then
		new_report(item)
	elseif item.kind == "reference" or item.kind == "reference_item" or item.kind == "reference_new" then
		require("aero.reference").open(item.wt.path)
	else
		choose_agent(item)
	end
end

function actions.add_workspace()
	M.add_workspace()
end

function actions.move()
	local item = current_item()
	if not item or item.kind ~= "report" then
		return
	end
	require("aero.workspaces").worktrees({
		title = "move report to worktree",
		exclude = item.wt.path,
		select = function(destination)
			local wt, ws = destination.wt, destination.ws
			local report, move_err = reports.move(item.report, wt.path, ws)
			if not report then
				notify(move_err, vim.log.levels.WARN)
				return
			end
			state.expanded[wt.path], state.reports_expanded[wt.path] = true, true
			store.set_expanded(ws.root, true)
			item.id = "report:" .. report.path
			M.render()
		end,
	})
end

function actions.rename()
	local item = current_item()
	if not item then
		return
	end
	if item.kind == "board" then
		vim.ui.input(
			{ prompt = "Rename board: ", default = item.board.metadata and item.board.metadata.title },
			function(name)
				if not name or vim.trim(name) == "" then
					return
				end
				local ok, err = require("aero.tasks").rename_board(item.ws, item.board.path, vim.trim(name))
				if not ok then
					notify(err, vim.log.levels.WARN)
				end
				M.render()
			end
		)
	elseif item.kind == "reference_item" then
		local entry = item.reference
		local stem = entry.kind ~= "directory" and entry.name:match("^(.+)%.[^.]+$")
		require("aero.input").input({
			prompt = "Rename reference item: ", default = entry.name, select_length = stem and #stem or nil,
		}, function(name)
			if not name or vim.trim(name) == "" then return end
			local renamed, err = require("aero.reference").rename(entry, name)
			if not renamed then return notify(err, vim.log.levels.WARN) end
			local expanded = {}
			for path, value in pairs(state.reference_folders_expanded) do
				if path == entry.path or vim.startswith(path, entry.path .. "/") then
					expanded[renamed.path .. path:sub(#entry.path + 1)] = value
				else
					expanded[path] = value
				end
			end
			state.reference_folders_expanded = expanded
			item.id = "reference-item:" .. renamed.path
			require("aero.events").emit("reference_changed", { worktree = item.wt.path })
		end)
	elseif item.kind == "report" then
		reports.rename(item.report, function(report)
			item.id = "report:" .. report.path
			M.render()
		end)
	elseif item.kind == "session" then
		require("aero.input").input({ prompt = "Rename session: ", default = item.session.name }, function(name)
			if not name or vim.trim(name) == "" then
				return
			end
			name = vim.trim(name)
			if name:find("%c") then
				notify("use a session name without control characters", vim.log.levels.WARN)
				return
			end
			local ok, err = session.rename(item.session, name)
			if not ok then
				notify(err, vim.log.levels.WARN)
			end
		end)
	end
end

function actions.delete()
	local item = current_item()
	if not item then
		return
	end
	if item.kind == "board" then
		if vim.fn.confirm("Permanently delete board and ALL its tickets?", "&Yes\n&No", 2) ~= 1 then
			return
		end
		local ok, err = require("aero.tasks").delete_board(item.ws, item.board.path)
		if not ok then
			notify(err, vim.log.levels.WARN)
			return
		end
	elseif item.kind == "reference_item" then
		local entry = item.reference
		local label = entry.kind == "directory" and "reference folder and all its contents" or "reference item"
		if vim.fn.confirm("Delete " .. label .. " " .. entry.name .. "?", "&Yes\n&No", 2) ~= 1 then
			return
		end
		local ok, err
		if entry.kind == "directory" then
			ok = vim.fn.delete(entry.path, "rf") == 0
			err = "could not remove folder: " .. entry.path
		else
			ok, err = vim.uv.fs_unlink(entry.path)
		end
		if not ok then
			notify("could not delete reference item: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		require("aero.events").emit("reference_changed", { worktree = item.wt.path })
	elseif item.kind == "report" or item.kind == "export" then
		local label = item.kind == "export" and "exported log" or "report"
		if vim.fn.confirm("Delete " .. label .. " " .. item.report.name .. "?", "&Yes\n&No", 2) ~= 1 then
			return
		end
		local ok, err = vim.uv.fs_unlink(item.report.path)
		if not ok then
			notify("could not delete " .. label .. ": " .. err, vim.log.levels.ERROR)
			return
		end
	elseif item.kind == "session" then
		local s = item.session
		local prompt = (s.job and "Kill running session " or "Delete session ") .. s.name .. "?"
		if vim.fn.confirm(prompt, "&Yes\n&No", 2) ~= 1 then
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
			require("aero.buffers").forget(wt.path)
			state.worktrees[ws.root] = nil
			notify("removed " .. vim.fn.fnamemodify(wt.path, ":~"))
			load_worktrees()
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
			require("aero.buffers").forget(wt.path)
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
		if use_panel and not enter_worktree(item.session.worktree) then
			return
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

local function yank(value)
	if value then
		vim.fn.setreg(vim.v.register, value, "v")
		if vim.v.register == '"' then
			vim.fn.setreg("0", value, "v")
		end
		notify("yanked " .. value)
	end
end

function actions.yank_name()
	local item = current_item()
	if not item then
		return
	end
	local name
	if item.kind == "workspace" then
		name = item.ws.name
	elseif item.kind == "worktree" then
		name = wt_label(item.wt)
	elseif item.kind == "session" then
		name = item.session.name
	elseif item.kind == "report" or item.kind == "export" then
		name = item.report.name
	elseif item.kind == "board" then
		name = tostring(
			item.board.metadata and item.board.metadata.title or vim.fs.basename(vim.fs.dirname(item.board.path))
		)
	end
	yank(name)
end

function actions.yank_path()
	local item = current_item()
	if not item then
		return
	end
	local path = item.report and item.report.path or item.board and item.board.path or item_dir(item)
	if path then
		yank(vim.fs.normalize(vim.fn.fnamemodify(path, ":p")))
	end
end

--- Pull the dashboard selection, or the current tab's checkout when called outside it.
function M.pull(path)
	if not path then
		if api.nvim_get_current_buf() == state.buf then
			path = item_dir(current_item())
			if not path then
				notify("move the cursor to a worktree first", vim.log.levels.WARN)
				return
			end
		else
			local s = session.from_buf(0)
			path = s and s.worktree or vim.t.aero_worktree or vim.fn.getcwd()
		end
	end
	path = vim.fs.normalize(vim.fn.resolve(path))
	if state.pulling[path] then
		notify("a pull is already running for " .. vim.fn.fnamemodify(path, ":~"), vim.log.levels.WARN)
		return
	end
	state.pulling[path] = true
	notify("pulling " .. vim.fn.fnamemodify(path, ":~") .. " …")
	return git.pull(path, function(ok, output)
		state.pulling[path] = nil
		-- Git may have fetched new refs even if it could not fast-forward the checkout.
		state.worktrees = {}
		load_worktrees()
		M.render()
		if not ok then
			notify("pull failed: " .. output, vim.log.levels.ERROR)
			return
		end
		vim.cmd("checktime")
		notify("pulled " .. vim.fn.fnamemodify(path, ":~") .. (output ~= "" and ("\n" .. output) or ""))
	end)
end

function actions.pull()
	M.pull()
end

function actions.switch_branch()
	local item = current_item()
	if not item or not item.wt then
		return notify("move the cursor to a worktree first", vim.log.levels.WARN)
	end
	local path = item.wt.path
	git.branches(path, function(branches, err)
		if not branches then
			return notify(err, vim.log.levels.ERROR)
		end
		vim.ui.select(branches, {
			prompt = "Switch branch (" .. wt_label(item.wt) .. "):",
			format_item = function(branch)
				return branch.name .. (branch.remote and " (remote)" or branch.name == item.wt.branch and " (current)" or "")
			end,
		}, function(branch)
			if not branch then
				return
			end
			git.switch_branch(path, branch, function(ok, switch_err)
				if not ok then
					return notify("branch switch failed: " .. switch_err, vim.log.levels.ERROR)
				end
				state.worktrees = {}
				load_worktrees()
				M.render()
				vim.cmd("checktime")
				notify("switched " .. vim.fn.fnamemodify(path, ":~") .. " to " .. branch.name)
			end)
		end)
	end)
end

function actions.review()
	require("aero.review").open()
end

function actions.cd()
	local dir = item_dir(current_item())
	if dir then
		if not tabs.available(dir) then
			return
		end
		vim.cmd.tcd(vim.fn.fnameescape(dir))
		notify("tcd " .. vim.fn.fnamemodify(dir, ":~"))
	end
end

function M.open_worktree(dir, opener)
	return navigation.open_worktree(dir, opener)
end

function actions.edit(restore)
	local item = current_item()
	if item and item.kind == "board" then
		api.nvim_set_current_win(M.code_window())
		vim.cmd.edit(vim.fn.fnameescape(item.board.path))
		return
	end
	if item and (item.kind == "boards" or item.kind == "board_new") then
		return require("aero.tasks.ui").new_board(item.ws)
	end
	if item and (item.kind == "report" or item.kind == "export") then
		return open_report(item)
	end
	if item and item.kind == "report_new" then
		return new_report(item)
	end
	local dir = item_dir(current_item())
	if dir then
		if restore then
			M.open_worktree(dir)
		else
			navigation.browse_worktree(dir)
		end
	end
end

function actions.open_board_markdown()
	local item = current_item()
	if item and item.kind == "board" then
		actions.edit()
		vim.b.aero_board_path, vim.b.aero_workspace_root = item.board.path, item.ws.root
	end
end

--- Open the dashboard-selected board source, returning whether a board was selected.
function M.open_board_markdown()
	if api.nvim_get_current_buf() ~= state.buf then
		return false
	end
	local item = current_item()
	if not item or item.kind ~= "board" then
		return false
	end
	actions.open_board_markdown()
	return true
end

function actions.edit_enter()
	actions.edit(true)
end

function actions.edit_mouse()
	local mouse = vim.fn.getmousepos()
	if mouse.winid == 0 or not api.nvim_win_is_valid(mouse.winid) then
		return
	end
	if api.nvim_win_get_buf(mouse.winid) ~= state.buf or mouse.line < 1 then
		return
	end
	local item = state.items[mouse.line]
	if not item_dir(item) then
		return
	end
	api.nvim_set_current_win(mouse.winid)
	state.win = mouse.winid
	api.nvim_win_set_cursor(mouse.winid, { mouse.line, 0 })
	actions.edit(true)
end

function actions.terminal()
	local dir = item_dir(current_item())
	if dir then
		if not enter_worktree(dir) then
			return
		end
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
	open = "open session or report / toggle node",
	expand = "expand node / open session or report",
	collapse = "collapse node / go to parent",
	toggle = "toggle node",
	open_vsplit = "open session or report in vsplit",
	open_split = "open session or report in split",
	open_tab = "open session or report in tab",
	add = "add: worktree / agent session / report (on Reports)",
	add_workspace = "add workspace",
	delete = "delete selected item: session (confirm) / report (confirm) / worktree / workspace",
	rename = "rename selected session, report, or board",
	move = "move selected report to another worktree",
	yank_name = "copy selected item name",
	yank_path = "copy selected item absolute path",
	stop = "stop session",
	restart = "restart session (resume)",
	refresh = "refresh git worktrees",
	pull = "pull worktree upstream (fast-forward only)",
	switch_branch = "switch worktree branch",
	review = "review worktree changes",
	cd = ":tcd to worktree",
	edit = "browse worktree source (Oil or directory browser)",
	open_board_markdown = "open selected board's raw Markdown file",
	edit_enter = "open worktree / restore last code buffer",
	edit_mouse = "open clicked worktree / restore last code buffer",
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
	if config.options.quote_key then
		table.insert(
			lines,
			("  %-8s quote selection (Visual mode in code / agent logs)"):format(config.options.quote_key)
		)
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
	buf = buf or state.buf
	if not buf or not api.nvim_buf_is_valid(buf) then
		return
	end
	for _, binding in ipairs(state.bindings) do
		if binding.buf == buf then
			api.nvim_buf_call(buf, function()
				local current = vim.fn.maparg(binding.lhs, "n", false, true)
				if current.callback == binding.callback then
					vim.keymap.del("n", binding.lhs, { buffer = buf })
				end
			end)
		end
	end
	state.bindings = {}
	local keys = config.options.keymaps
	local function map(lhs, fn, desc)
		if lhs then
			vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Aero: " .. desc })
			table.insert(state.bindings, { buf = buf, lhs = lhs, callback = fn })
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
			if not enter_worktree(c.session.worktree) then
				return
			end
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

require("aero.events").on("reports_changed", function()
	M.render()
end)
require("aero.events").on("reference_changed", function()
	M.render()
end)
require("aero.events").on("tasks_view_changed", function()
	M.render()
end)
require("aero.events").on("workspace_added", function()
	if state.buf and api.nvim_buf_is_valid(state.buf) then
		load_worktrees()
		M.render()
	end
end)
api.nvim_create_autocmd("User", {
	group = "Aero.dashboard",
	pattern = "AeroTaskChanged",
	callback = function()
		M.render()
	end,
})

-- spin busy sessions' icons and keep their activity current
spinner.on_frame(function()
	local busy = vim.iter(session.all()):any(function(s)
		return session.status(s) == "busy"
	end)
	if busy and state.buf and api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) ~= -1 then
		animate()
	end
	return busy
end)

return M
