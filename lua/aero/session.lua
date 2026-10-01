-- Agent sessions: an agent CLI in a :terminal, or an ACP agent driven through a chat buffer.
local config = require("aero.config")
local store = require("aero.store")
local spinner = require("aero.spinner")

local M = {}

---@class aero.Session
---@field key string
---@field worktree string
---@field name string
---@field agent string
---@field buf? integer
---@field job? integer
---@field exit_code? integer
---@field last_output? integer
---@field status? string
---@field chat? aero.acp.Chat  set for ACP sessions
---@field fresh? boolean  created in this nvim instance and never started (start without resuming)

---@type table<string, aero.Session>
local runtime = {}
local listeners = {}
local timer

local function key(worktree, name)
	return worktree .. "::" .. name
end

local function emit()
	for _, fn in ipairs(listeners) do
		pcall(fn)
	end
end
M.emit = emit

local function is_acp(s)
	local agent = config.options.agents[s.agent]
	return agent and agent.type == "acp"
end

local function running(s)
	if s.chat then
		return s.chat:alive()
	end
	return s.job ~= nil
end

function M.on_change(fn)
	table.insert(listeners, fn)
end

---@return "busy"|"idle"|"waiting"|"exited"|"stopped"
function M.status(s)
	if s.chat then
		return s.chat:status()
	end
	if not s.job then
		return s.exit_code and "exited" or "stopped"
	end
	if vim.uv.now() - (s.last_output or 0) < config.options.idle_ms then
		return "busy"
	end
	return "idle"
end

--- What an ACP session is doing right now ("thinking", a tool's title, …); nil otherwise.
function M.activity(s)
	return s.chat and s.chat:activity() or nil
end

--- The icon for a session's status, spinning while it is busy.
function M.icon(s)
	local st = M.status(s)
	return st == "busy" and spinner.frame() or config.options.icons[st]
end

local function get(worktree, name)
	local k = key(worktree, name)
	if not runtime[k] then
		for _, def in ipairs(store.sessions(worktree)) do
			if def.name == name then
				runtime[k] = { key = k, worktree = worktree, name = name, agent = def.agent }
			end
		end
	end
	return runtime[k]
end

---@return aero.Session[]
function M.list(worktree)
	local out = {}
	for _, def in ipairs(store.sessions(worktree)) do
		table.insert(out, get(worktree, def.name))
	end
	return out
end

---@return aero.Session[]
function M.all()
	local out = {}
	for worktree in pairs(store.data.sessions) do
		vim.list_extend(out, M.list(worktree))
	end
	return out
end

--- Register a new (not yet started) session of `agent` in `worktree`.
function M.create(worktree, agent)
	local name = store.add_session(worktree, agent, function(n)
		return runtime[key(worktree, n)] ~= nil
	end)
	local s = get(worktree, name)
	s.fresh = true
	emit()
	return s
end

local function notify_idle(s)
	if config.options.notify_idle and s.buf and vim.fn.bufwinid(s.buf) == -1 then
		vim.notify(("aero: %s in %s is done"):format(s.name, vim.fn.fnamemodify(s.worktree, ":~")), vim.log.levels.INFO)
	end
end

local function tick()
	local changed, any = false, false
	for _, s in pairs(runtime) do
		local st = M.status(s)
		any = any or running(s)
		if st ~= s.status then
			if s.status == "busy" and st == "idle" then
				notify_idle(s)
			end
			s.status, changed = st, true
		end
		if st == "busy" then
			spinner.ensure()
		end
	end
	if changed then
		emit()
	end
	if not any and timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

local function ensure_timer()
	if not timer then
		timer = vim.uv.new_timer()
		timer:start(300, 300, vim.schedule_wrap(tick))
	end
end

local function resolve_cmd(cmd, s)
	if type(cmd) == "function" then
		return cmd(s)
	end
	return cmd
end

--- Start (or restart) the session's agent in a new buffer shown in `win`.
function M.start(s, win, resume)
	local agent = config.options.agents[s.agent]
	if not agent then
		vim.notify("aero: unknown agent " .. s.agent, vim.log.levels.ERROR)
		return false
	end
	M.stop(s)
	local old = s.buf
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_win_set_buf(win, buf)
	local function cleanup_old()
		if old and old ~= buf and vim.api.nvim_buf_is_valid(old) then
			vim.api.nvim_buf_delete(old, { force = true })
		end
	end
	local function on_wipe()
		vim.api.nvim_create_autocmd("BufWipeout", {
			buffer = buf,
			once = true,
			callback = function()
				if s.buf == buf then
					if s.chat then
						s.chat:stop()
					end
					s.buf, s.job, s.chat = nil, nil, nil
					vim.schedule(emit)
				end
			end,
		})
	end

	if agent.type == "acp" then
		s.buf, s.job, s.exit_code, s.fresh = buf, nil, nil, false
		s.chat = require("aero.acp").start(s, buf, agent, resume)
		if not s.chat then
			s.buf = nil
			vim.api.nvim_buf_delete(buf, { force = true })
			return false
		end
		on_wipe()
		cleanup_old()
		ensure_timer()
		emit()
		return true
	end

	local cmd = resolve_cmd(resume and agent.resume or agent.cmd, s)
	s.chat = nil
	local ok, job = pcall(vim.api.nvim_win_call, win, function()
		return vim.fn.jobstart(cmd, {
			term = true,
			cwd = s.worktree,
			env = agent.env,
			on_exit = function(id, code)
				vim.schedule(function()
					if s.job == id then
						s.job, s.exit_code = nil, code
						s.status = M.status(s)
						emit()
					end
				end)
			end,
		})
	end)
	if not ok or job <= 0 then
		vim.api.nvim_buf_delete(buf, { force = true })
		vim.notify(
			("aero: failed to start %s: %s"):format(table.concat(cmd, " "), ok and "not executable" or job),
			vim.log.levels.ERROR
		)
		return false
	end

	s.buf, s.job, s.exit_code, s.fresh = buf, job, nil, false
	s.last_output = vim.uv.now()
	s.status = M.status(s)
	vim.b[buf].aero_session = s.key
	pcall(vim.api.nvim_buf_set_name, buf, ("aero://%s#%s"):format(s.worktree, s.name))
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function()
			if s.buf ~= buf then
				return true
			end
			s.last_output = vim.uv.now()
		end,
	})
	on_wipe()
	cleanup_old()
	ensure_timer()
	emit()
	return true
end

local function tab_wins_with(buf)
	local tab = vim.api.nvim_get_current_tabpage()
	return vim.tbl_filter(function(w)
		return vim.api.nvim_win_get_tabpage(w) == tab
	end, vim.fn.win_findbuf(buf))
end

--- Make `win` ready to receive a session buffer, returning the window to actually use.
--- A window showing an ACP prompt is swapped for its transcript window, and the prompt split
--- of the session being replaced is closed, so switching sessions doesn't leave stale prompts.
function M.prepare_win(win)
	local owner = runtime[vim.b[vim.api.nvim_win_get_buf(win)].aero_chat_key or ""]
	if owner and owner.buf and #vim.api.nvim_tabpage_list_wins(0) > 1 then
		local tw = tab_wins_with(owner.buf)[1]
		if tw and tw ~= win then
			vim.api.nvim_win_close(win, false)
			win = tw
		end
	end
	local s = M.from_buf(vim.api.nvim_win_get_buf(win))
	local prompt = s and s.chat and s.chat.prompt_buf
	if prompt and vim.api.nvim_buf_is_valid(prompt) then
		for _, w in ipairs(tab_wins_with(prompt)) do
			if w ~= win and #vim.api.nvim_tabpage_list_wins(0) > 1 then
				vim.api.nvim_win_close(w, false)
			end
		end
	end
	return win
end

--- Show the session, starting it if it isn't running. Focuses an existing window in this tab
--- when the session is already visible; otherwise uses `win`.
--- Sessions not created in this nvim instance are resumed rather than started fresh.
---@return integer? win the window the session is shown in, nil on failure
function M.show(s, win, reuse)
	if running(s) and s.buf and vim.api.nvim_buf_is_valid(s.buf) then
		local visible = reuse ~= false and tab_wins_with(s.buf)[1]
		if visible then
			return visible
		end
		win = M.prepare_win(win)
		vim.api.nvim_win_set_buf(win, s.buf)
		return win
	end
	win = M.prepare_win(win)
	return M.start(s, win, not s.fresh) and win or nil
end

function M.stop(s)
	if s.chat then
		s.chat:stop()
	end
	if s.job then
		vim.fn.jobstop(s.job)
	end
end

--- Put focus into the session for typing: insert mode in a terminal, the prompt buffer for ACP
--- (or the options of a pending permission request).
function M.enter(s)
	if s.chat and s.chat.permission then
		-- the agent is waiting on a permission request: go to its options instead
		s.chat:goto_permission(true)
	elseif s.chat then
		s.chat:compose()
	else
		vim.cmd.startinsert()
	end
end

function M.is_running(s)
	return running(s)
end

function M.delete(s)
	M.stop(s)
	if is_acp(s) then
		require("aero.acp").forget(s)
	end
	if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
		local buf = s.buf
		s.buf = nil
		vim.api.nvim_buf_delete(buf, { force = true })
	end
	runtime[s.key] = nil
	store.remove_session(s.worktree, s.name)
	emit()
end

function M.delete_worktree(worktree)
	for _, s in ipairs(M.list(worktree)) do
		M.delete(s)
	end
end

--- Session for a terminal buffer, if it belongs to aero.
function M.from_buf(buf)
	local k = vim.b[buf or 0].aero_session
	return k and runtime[k]
end

return M
