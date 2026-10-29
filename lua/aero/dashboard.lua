-- The dashboard: a read-only tree buffer of workspaces > worktrees > agent sessions.
local config = require("aero.config")
local store = require("aero.store")
local git = require("aero.git")
local session = require("aero.session")
local panel = require("aero.panel")
local tabs = require("aero.tabs")
local terminal = require("aero.terminal")
local reports = require("aero.reports")
local navigation = require("aero.navigation")
local M = {}
local api = vim.api
local state = {
	buf = nil, ---@type integer?
	win = nil, ---@type integer?
	target = nil, ---@type integer? window sessions and files are opened in
	items = {}, ---@type table<integer, table> line number -> item
	worktrees = {}, ---@type table<string, {list?: aero.Worktree[], err?: string}> workspace root -> cache
	expanded = {}, ---@type table<string, boolean> worktree path -> expanded
	reports_expanded = {}, -- worktree path -> report section expanded
	reading_expanded = {}, -- worktree path -> reading lists section expanded
	reference_expanded = {}, -- worktree path -> reference section expanded
	reference_folders_expanded = {}, -- reference directory path -> expanded
	exports_expanded = {}, -- worktree path -> exported logs section expanded
	boards_expanded = {}, -- workspace root -> board section expanded
	submodules_expanded = {}, -- checkout path -> submodule section expanded
	repositories_expanded = {}, -- submodule checkout path -> repository expanded
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

local invalidate = function()
	M.render()
end

local function remote_changed()
	invalidate()
end

local function worktrees(ws, force)
	local cache = state.worktrees[ws.root]

	if force or not cache then
		local list, err = git.list(ws.root)
		cache = { list = list, err = err }
		state.worktrees[ws.root] = cache
	end

	return cache
end

-- Top-level repository loading and remote requests are explicit. Nested local
-- discovery is queued only for expanded submodule sections while preparing snapshots.
local function load_worktrees()
	local roots = {}

	for _, workspace in ipairs(store.data.workspaces) do
		if workspace.expanded ~= false then
			worktrees(workspace)

			if state.worktrees[workspace.root].list then
				table.insert(roots, workspace.root)
			end
		end
	end

	for _, root in ipairs(roots) do
		require("aero.remote_status").request(root, remote_changed)
	end
end

local function wt_expanded(wt, sessions)
	return require("aero.dashboard.snapshot").worktree_expanded(state, wt, sessions)
end

local function wt_label(wt)
	if wt.branch then
		return wt.branch
	end

	return "(detached " .. (wt.head or ""):sub(1, 7) .. ")"
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------

local animation_snapshot
local rendering, render_again = false, false

local function build()
	local snapshot = require("aero.dashboard.snapshot").prepare(store.data.workspaces, state, remote_changed)
	animation_snapshot = snapshot
	return require("aero.dashboard.model").build(snapshot)
end

-- Animation must not rescan the filesystem or invoke task metadata subprocesses.
local function animate()
	if rendering or not animation_snapshot then
		return
	end

	require("aero.dashboard.snapshot").refresh_sessions(animation_snapshot)
	local lines, items, marks = require("aero.dashboard.model").build(animation_snapshot)
	require("aero.dashboard.view").render(state, lines, items, marks)
end

--- Collapse all existing sidebar nodes of a type, including hidden descendants.
function M.collapse(kind)
	kind = kind or "all"

	if kind == "context" then
		kind = "reference"
	end -- legacy command alias

	local valid = {
		all = true,
		workspaces = true,
		worktrees = true,
		reports = true,
		reading = true,
		exports = true,
		boards = true,
		reference = true,
	}

	if not valid[kind] then
		notify(
			"use :Aero collapse [all|workspaces|worktrees|reading|reports|exports|boards|reference]",
			vim.log.levels.WARN
		)
		return
	end

	if kind == "all" or kind == "reference" then
		state.reference_folders_expanded = {}
	end

	if kind == "all" then
		state.submodules_expanded, state.repositories_expanded = {}, {}
	end

	local sections = {
		worktrees = state.expanded,
		reports = state.reports_expanded,
		reading = state.reading_expanded,
		exports = state.exports_expanded,
		reference = state.reference_expanded,
	}

	for name, section in pairs(sections) do
		if kind == "all" or kind == name then
			for path in pairs(section) do
				section[path] = false
			end
		end
	end

	for _, repository in ipairs(require("aero.submodules").known_repositories()) do
		for _, wt in ipairs(repository.list) do
			for name, section in pairs(sections) do
				if kind == "all" or kind == name then
					section[wt.path] = false
				end
			end
		end
	end

	for _, ws in ipairs(store.data.workspaces) do
		if kind == "all" or kind == "boards" then
			state.boards_expanded[ws.root] = false
		end

		if
			kind == "all"
			or kind == "worktrees"
			or kind == "reports"
			or kind == "exports"
			or kind == "reference"
			or kind == "reading"
		then
			local cache = state.worktrees[ws.root]
			local list = cache and cache.list or git.list(ws.root)

			for _, wt in ipairs(list or {}) do
				if kind == "all" or kind == "reading" then
					state.reading_expanded[wt.path] = false
				end

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

	if rendering then
		render_again = true
		return
	end

	rendering = true
	local ok, lines, items, marks = pcall(build)

	if not ok then
		rendering = false
		error(lines)
	end

	require("aero.dashboard.view").render(state, lines, items, marks)

	if state.reveal_path and state.win and api.nvim_win_is_valid(state.win) then
		for row, item in pairs(items) do
			if item.kind == "worktree" and item.wt.path == state.reveal_path then
				api.nvim_win_set_cursor(state.win, { row, 0 })
				state.reveal_path = nil
				break
			end
		end
	end

	rendering = false

	if render_again then
		render_again = false
		vim.schedule(M.render)
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

function M.open(focus_worktree)
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
		require("aero.layout").set_buf(cur, buf)
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
	local selected_path

	if focus_worktree then
		local path = vim.fs.normalize(vim.fn.resolve(vim.t.aero_worktree or vim.fn.getcwd()))

		for _, repository in
			ipairs(require("aero.repositories").list(function(ws)
				local cache = worktrees(ws)
				return cache.list, cache.err
			end))
		do
			local ws = repository.ws

			for _, wt in ipairs(repository.list) do
				local root = vim.fs.normalize(vim.fn.resolve(wt.path))

				if root == path or (not vim.t.aero_worktree and path:sub(1, #root + 1) == root .. "/") then
					if not selected_path or #wt.path > #selected_path then
						ws.expanded = true
						selected_path = wt.path
					end
				end
			end
		end

		local ancestor = selected_path and require("aero.submodules").ancestry(selected_path)
		while ancestor do
			state.expanded[ancestor.worktree] = true
			state.submodules_expanded[ancestor.worktree] = true
			state.repositories_expanded[ancestor.mount] = true

			for _, ws in ipairs(store.data.workspaces) do
				for _, wt in ipairs(worktrees(ws).list or {}) do
					if wt.path == ancestor.worktree then
						ws.expanded = true
					end
				end
			end

			ancestor = ancestor.parent
		end
		state.reveal_path = selected_path
	end

	require("aero.submodules").invalidate(true)
	load_worktrees()
	M.render()

	if selected_path then
		for row, item in pairs(state.items) do
			if item.kind == "worktree" and item.wt.path == selected_path then
				api.nvim_win_set_cursor(state.win, { row, 0 })
				break
			end
		end
	end

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
			require("aero.layout").set_buf(state.win, alt)
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
		local win = api.nvim_get_current_win()
		M.open(not panel.owns(win) and not terminal.is_term_win(win))
	end
end

function M.refresh()
	store.load()
	require("aero.submodules").invalidate(true)
	require("aero.remote_status").invalidate()
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
			require("aero.submodules").invalidate(true)
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
	return require("aero.dashboard.session_actions").start(item, agent, function(s)
		state.expanded[s.worktree] = true
	end)
end

local function choose_agent(item, label)
	return require("aero.dashboard.session_actions").choose(item, label, function(s)
		state.expanded[s.worktree] = true
	end)
end

--- Choose an agent without requiring a sidebar selection.
function M.new()
	local path = vim.t.aero_worktree or vim.fn.getcwd()
	choose_agent({ wt = { path = path } }, vim.fn.fnamemodify(path, ":~"))
end

function M.add_workspace(path)
	return require("aero.dashboard.repository_actions").add_workspace(path, function()
		load_worktrees()
		M.render()
	end)
end

local function add_worktree(ws)
	return require("aero.dashboard.repository_actions").add_worktree(ws, function(workspace, branch)
		state.worktrees[workspace.root] = nil

		for _, wt in ipairs(worktrees(workspace).list or {}) do
			if wt.branch == branch then
				state.expanded[wt.path] = true
			end
		end

		M.render()
	end)
end

local actions = {}

local function open_reading(item, create)
	return require("aero.dashboard.document_actions").reading(item, create, function()
		state.reading_expanded[item.wt.path] = true
	end)
end

local function open_report(item, how)
	local win = require("aero.dashboard.document_actions").open(item, how)

	if win then
		state.target = win
	end
end

local function new_report(item)
	require("aero.dashboard.document_actions").create_report(item, function(report)
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
	elseif item.kind == "reading_list" or item.kind == "reading_new" then
		open_reading(item, item.kind == "reading_new")
	else
		actions.toggle()
	end
end

function actions.toggle()
	local item = current_item()

	if not item then
		return
	end

	if item.kind == "submodules" then
		state.submodules_expanded[item.wt.path] = not state.submodules_expanded[item.wt.path]
	elseif item.kind == "submodule" then
		if not item.submodule.initialized then
			return
		end

		state.repositories_expanded[item.submodule.path] = not state.repositories_expanded[item.submodule.path]
	elseif item.kind == "workspace" then
		store.set_expanded(item.ws.root, item.ws.expanded == false)
		load_worktrees()
	elseif item.kind == "worktree" then
		state.expanded[item.wt.path] = not wt_expanded(item.wt, session.list(item.wt.path))
	elseif item.kind == "exports" then
		state.exports_expanded[item.wt.path] = state.exports_expanded[item.wt.path] == false
	elseif item.kind == "reports" then
		state.reports_expanded[item.wt.path] = state.reports_expanded[item.wt.path] == false
	elseif item.kind == "reading" then
		state.reading_expanded[item.wt.path] = state.reading_expanded[item.wt.path] == false
	elseif item.kind == "reference" then
		state.reference_expanded[item.wt.path] = state.reference_expanded[item.wt.path] == false
	elseif item.kind == "reference_item" and item.reference.kind == "directory" then
		state.reference_folders_expanded[item.reference.path] =
			not state.reference_folders_expanded[item.reference.path]
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
		or item.kind == "reading_list"
		or item.kind == "reading_new"
		or item.kind == "reference_item" and item.reference.kind ~= "directory"
		or item.kind == "reference_new"
		or item.kind == "board"
		or item.kind == "board_new"
		or item.kind == "tickets_removed"
	then
		return actions.open("default")
	end

	local expanded

	if item.kind == "submodules" then
		expanded = state.submodules_expanded[item.wt.path] == true
	elseif item.kind == "submodule" then
		expanded = state.repositories_expanded[item.submodule.path] == true
	elseif item.kind == "workspace" then
		expanded = item.ws.expanded ~= false
	elseif item.kind == "exports" then
		expanded = state.exports_expanded[item.wt.path] ~= false
	elseif item.kind == "reports" then
		expanded = state.reports_expanded[item.wt.path] ~= false
	elseif item.kind == "reading" then
		expanded = state.reading_expanded[item.wt.path] ~= false
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
		or item.kind == "worktree"
		or item.kind == "submodules"
		or item.kind == "submodule"
		or item.id:match("^wt:")
		or item.kind == "reports"
		or item.kind == "reading"
		or item.kind == "reference"
		or item.kind == "reference_item" and item.reference.kind == "directory"
		or item.kind == "boards"
		or item.kind == "exports"
	local open = item.kind == "workspace" and item.ws.expanded ~= false
		or item.kind == "submodules" and state.submodules_expanded[item.wt.path] == true
		or item.kind == "submodule" and state.repositories_expanded[item.submodule.path] == true
		or item.kind == "worktree" and wt_expanded(item.wt, session.list(item.wt.path))
		or item.kind == "reports" and state.reports_expanded[item.wt.path] ~= false
		or item.kind == "reading" and state.reading_expanded[item.wt.path] ~= false
		or item.kind == "reference" and state.reference_expanded[item.wt.path] ~= false
		or item.kind == "reference_item" and state.reference_folders_expanded[item.reference.path] == true
		or item.kind == "exports" and state.exports_expanded[item.wt.path] ~= false
		or item.kind == "boards" and state.boards_expanded[item.ws.root] ~= false

	if is_header and open then
		return actions.toggle()
	end

	-- jump to the parent line
	local parent = item.parent
		or (item.kind == "board" or item.kind == "board_new" or item.kind == "tickets_removed") and "boards:" .. item.ws.root
		or item.kind == "export" and "exports:" .. item.wt.path
		or item.kind == "exports" and "wt:" .. item.wt.path
		or (item.kind == "report" or item.kind == "report_new") and "reports:" .. item.wt.path
		or (item.kind == "reading_list" or item.kind == "reading_new") and "reading:" .. item.wt.path
		or item.kind == "reading" and "wt:" .. item.wt.path
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
	elseif item.kind == "workspace" or item.kind == "submodule" then
		add_worktree(item.ws)
	elseif item.kind == "reports" or item.kind == "report" or item.kind == "report_new" then
		new_report(item)
	elseif item.kind == "reading" or item.kind == "reading_list" or item.kind == "reading_new" then
		open_reading(item, true)
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
	return require("aero.dashboard.document_actions").move(item, function(report, wt, ws)
		state.expanded[wt.path], state.reports_expanded[wt.path] = true, true
		store.set_expanded(ws.root, true)
		item.id = "report:" .. report.path
		M.render()
	end)
end

function actions.rename()
	local item = current_item()

	if not item then
		return
	end

	if item.kind == "session" then
		return require("aero.dashboard.session_actions").rename(item.session, M.render)
	end

	local entry = item.reference
	require("aero.dashboard.document_actions").rename(item, function(renamed)
		if item.kind == "reference_item" then
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
		elseif item.kind == "report" then
			item.id = "report:" .. renamed.path
		end

		M.render()
	end)
end

function actions.delete()
	local item = current_item()

	if not item then
		return
	end

	if require("aero.dashboard.document_actions").delete(item, M.render) then
		return
	end

	if item.kind == "session" then
		require("aero.dashboard.session_actions").delete(item.session)
		M.render()
	else
		require("aero.dashboard.repository_actions").delete(item, worktrees, function(ws)
			state.worktrees[ws.root] = nil
			load_worktrees()
			M.render()
		end)
	end
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
		local win, use_panel = require("aero.dashboard.session_actions").restart(item.session, target_win)

		if win and not use_panel then
			state.target = win
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

	return require("aero.dashboard.repository_actions").pull(path, function()
		state.worktrees = {}
		load_worktrees()
		M.render()
	end)
end

function actions.pull()
	M.pull()
end

function actions.switch_branch()
	return require("aero.dashboard.repository_actions").switch_branch(current_item(), function()
		state.worktrees = {}
		load_worktrees()
		M.render()
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

function actions.help()
	require("aero.dashboard.keymaps").help()
end

function M.set_keymaps(buf)
	require("aero.dashboard.keymaps").apply(buf or state.buf, actions, function(name)
		start_agent(current_item(), name)
	end)
end

---------------------------------------------------------------------------
-- Pickers
---------------------------------------------------------------------------

--- Pick any session across all workspaces with vim.ui.select and open it in the panel
--- (or the current window when the panel is disabled).
function M.pick(scope)
	local choices = {}

	if scope == "current" then
		local path = vim.t.aero_worktree or vim.fn.getcwd()

		for _, s in ipairs(session.list(path)) do
			table.insert(choices, { session = s })
		end
	else
		for _, repository in
			ipairs(require("aero.repositories").list(function(ws)
				local cache = worktrees(ws)
				return cache.list, cache.err
			end))
		do
			local ws = repository.ws

			for _, wt in ipairs(repository.list) do
				for _, s in ipairs(session.list(wt.path)) do
					table.insert(choices, { ws = ws, wt = wt, session = s })
				end
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

			if scope == "current" then
				return ("%s %s [%s]%s"):format(
					session.icon(c.session),
					c.session.name,
					c.session.agent,
					what and "  " .. what or ""
				)
			end

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

local dispose_subscriptions

function M.teardown()
	if dispose_subscriptions then
		dispose_subscriptions()
		dispose_subscriptions = nil
	end
end

function M.setup()
	M.teardown()
	M.setup_highlights()
	M.set_keymaps()
	local function visible()
		return state.buf and api.nvim_buf_is_valid(state.buf) and vim.fn.bufwinid(state.buf) ~= -1
	end

	dispose_subscriptions, invalidate = require("aero.dashboard.subscriptions").attach({
		visible = visible,
		load = function()
			if state.buf and api.nvim_buf_is_valid(state.buf) then
				load_worktrees()
			end
		end,
		render = function()
			M.render()
		end,
		animate = function()
			local busy = vim.iter(session.all()):any(function(s)
				return session.status(s) == "busy"
			end)

			if busy and visible() then
				animate()
			end

			return busy
		end,
	})
end
return M
