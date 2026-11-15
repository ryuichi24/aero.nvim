-- Agent sessions: an agent CLI in a :terminal, or an ACP agent driven through a chat buffer.
local config = require("aero.config")
local store = require("aero.store")
local spinner = require("aero.spinner")
local history = require("aero.history")
local events = require("aero.events")
local registry = require("aero.session.registry")
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

local changes = require("aero.listeners").new("session change")

local function emit()
	changes.emit()
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
	return changes.on(fn)
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

local monitor = require("aero.session.monitor").new({
	sessions = registry.loaded,
	status = function(s)
		return M.status(s)
	end,
	running = running,
	changed = emit,
})

---@return aero.Session[]
function M.list(worktree)
	return registry.list(worktree)
end

---@return aero.Session[]
function M.all()
	return registry.all()
end

--- Register a new (not yet started) session of `agent` in `worktree`.
function M.create(worktree, agent, requested_name)
	local name, err = store.add_session(worktree, agent, function(n)
		return registry.identity_taken(worktree, n)
	end, requested_name)

	if not name then
		return nil, err
	end

	local s = registry.get(worktree, name)
	s.fresh = true
	emit()
	events.emit("session_created", events.session(s))
	return s
end

--- Change the display name while retaining runtime and history identity.
function M.rename(s, name)
	local ok, err = store.rename_session(s.worktree, s.name, name, s.key)

	if not ok then
		return nil, err
	end

	s.name = name
	emit()
	return true
end

-- Old buffers survive failed launches. Wipe handling is installed only after
-- the backend has accepted the new buffer as its runtime owner.
local function prepare_buffer(s, win, agent)
	local old = s.buf
	local buf = vim.api.nvim_create_buf(true, false)

	if win then
		require("aero.layout").set_buf(win, buf)
	end

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
				if agent.type ~= "acp" then
					require("aero.session.backends.terminal").cleanup(buf)
				end

				if s.buf == buf then
					if not s.chat then
						require("aero.session.backends.terminal").flush(s)
					end

					if s.chat then
						M.stop(s)
					elseif s.job then
						M.stop(s)
					end

					s.buf, s.job, s.chat = nil, nil, nil
					vim.schedule(emit)
				end
			end,
		})
	end

	return buf, on_wipe, cleanup_old
end

--- Start (or restart) the session's agent in a new buffer shown in `win`.
--- ACP sessions may use nil `win` to start without displaying the transcript.
--- An explicit ACP session ID is persisted only after the adapter accepts it.
--- Task assignment may supply staged tools (restore_tasks=false) and a one-shot
--- on_resume(chat, err) callback to commit or roll back after strict loading.
function M.start(s, win, resume, session_id, opts)
	opts = opts or {}
	win = win == 0 and vim.api.nvim_get_current_win() or win
	local agent = config.options.agents[s.agent]

	if not agent then
		vim.notify("aero: unknown agent " .. s.agent, vim.log.levels.ERROR)
		return false
	end

	if not win and agent.type ~= "acp" then
		return false
	end

	M.stop(s)
	local prepared, integration_err = require("aero.session.integrations").prepare(s, agent, opts)

	if not prepared then
		vim.notify("Aero: " .. integration_err, vim.log.levels.ERROR)
		return false
	end

	local buf, on_wipe, cleanup_old = prepare_buffer(s, win, agent)
	local kind = agent.type == "acp" and "acp" or "terminal"
	local started

	if kind == "acp" then
		started = require("aero.session.backends.acp").start(s, buf, agent, resume, session_id, opts)
	else
		started = require("aero.session.backends.terminal").start(s, win, resume, agent, buf, function(code)
			s.status = M.status(s)
			emit()
			events.emit("session_exited", events.session(s, { exit_code = code, type = "terminal" }))
		end)

		if started then
			s.status = M.status(s)
		end
	end

	if not started then
		return false
	end

	-- Commit buffer ownership and publish startup only after the backend accepts it.
	on_wipe()
	cleanup_old()
	monitor.ensure()
	s.stop_requested = false
	emit()

	if kind ~= "acp" or not opts.history_only then
		events.emit("session_started", events.session(s, { win = win, resume = resume == true, type = kind }))
	end

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
	local owner = registry.find(vim.b[vim.api.nvim_win_get_buf(win)].aero_chat_key or "")

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

--- Show the session, restoring stopped ACP history without starting the agent.
--- Focuses an existing window in this tab
--- when the session is already visible; otherwise uses `win`.
--- Terminal sessions not created in this nvim instance use their resume command.
---@return integer? win the window the session is shown in, nil on failure
function M.show(s, win, reuse)
	win = win == 0 and vim.api.nvim_get_current_win() or win

	if (running(s) or (is_acp(s) and s.chat)) and s.buf and vim.api.nvim_buf_is_valid(s.buf) then
		local visible = reuse ~= false and tab_wins_with(s.buf)[1]

		if visible then
			events.emit("session_shown", events.session(s, { win = visible }))
			return visible
		end

		win = M.prepare_win(win)
		require("aero.layout").set_buf(win, s.buf)
		events.emit("session_shown", events.session(s, { win = win }))
		return win
	end

	win = M.prepare_win(win)

	if M.start(s, win, not s.fresh, nil, { history_only = is_acp(s) and not s.fresh }) then
		events.emit("session_shown", events.session(s, { win = win }))
		return win
	end
end

function M.stop(s)
	local stopping = running(s) and not s.stop_requested

	if stopping then
		s.stop_requested = true
	end

	if s.chat then
		require("aero.session.backends.acp").stop(s)
	else
		require("aero.session.backends.terminal").stop(s)
	end

	if stopping then
		events.emit("session_stopped", events.session(s))
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
	elseif s.job then
		vim.cmd.startinsert()
	else
		vim.cmd.stopinsert()
	end
end

function M.is_running(s)
	return running(s)
end

function M.delete(s)
	local removed, err = store.remove_session(s.worktree, s.name)

	if not removed then
		return nil, err
	end

	require("aero.session.integrations").detach(s)
	local data = events.session(s)
	M.stop(s)

	if is_acp(s) then
		require("aero.session.backends.acp").forget(s)
	end

	if s.buf and vim.api.nvim_buf_is_valid(s.buf) then
		local buf = s.buf
		s.buf = nil
		vim.api.nvim_buf_delete(buf, { force = true })
	end

	registry.remove(s.key)
	history.remove(s)
	emit()
	events.emit("session_deleted", data)
	return true
end

function M.delete_worktree(worktree)
	for _, s in ipairs(M.list(worktree)) do
		M.delete(s)
	end
end

--- Session for a terminal buffer, if it belongs to aero.
function M.from_buf(buf)
	return registry.from_buf(buf)
end

return M
