-- ACP conversation owner: session lifecycle, turn queue and protocol state.
-- Editor collaborators operate on this owner through explicit calls; saved and wire
-- projections omit presentation caches and never persist live callbacks.
local store = require("aero.store")
local Client = require("aero.acp.client")
local spinner = require("aero.spinner")
local history = require("aero.history")
local events = require("aero.events")
local models = require("aero.acp.models")
local modes = require("aero.acp.modes")
local transcript = require("aero.acp.transcript")
local usage = require("aero.acp.usage")
require("aero.acp.types")

local M = {}

local api = vim.api

---@class Aero.acp.Chat
---@field s Aero.Session
---@field client? Aero.acp.Client
---@field buf integer transcript buffer
---@field prompt_buf? integer
---@field session_id? string
---@field state "starting"|"ready"|"exited"
---@field busy boolean
---@field blocks table[]
---@field tools table<string, table>
---@field permission? {params: table, respond: fun(result: any), block: table}
---@field permissions? {params: table, respond: fun(result: any), block: table}[]
---@field queue string[] prompts typed before the session was ready
local Chat = {}
Chat.__index = Chat

---@type table<string, Aero.acp.Chat> session key -> chat
local chats_by_key = {}

local function error_text(err)
	if type(err) ~= "table" then
		return err and tostring(err) or "unknown error"
	end
	local text = tostring(err.message or "unknown error")
	if err.code ~= nil then
		text = text .. " (code " .. tostring(err.code) .. ")"
	end
	if err.data ~= nil and err.data ~= vim.NIL then
		local detail = type(err.data) == "string" and err.data or vim.inspect(err.data)
		if detail ~= "" then
			text = text .. "\n" .. detail
		end
	end
	return text
end

local function content_text(c)
	if type(c) ~= "table" then
		return ""
	end
	if c.type == "text" then
		return c.text or ""
	elseif c.type == "resource_link" then
		return ("[%s](%s)"):format(c.name or c.uri, c.uri or "")
	elseif c.type == "resource" and c.resource then
		return c.resource.text or ("[%s]"):format(c.resource.uri or "resource")
	elseif c.type == "image" then
		return "[image]"
	end
	return ""
end

--- Agent-provided text shown on a single line (titles, option names, …) may contain newlines,
--- e.g. a multi-line shell command as a tool title; buffer lines can't.
local function one_line(text)
	return (tostring(text or ""):gsub("%s*\r?\n%s*", " ⏎ "))
end

---------------------------------------------------------------------------
-- Transcript rendering
---------------------------------------------------------------------------

function Chat:agent_title()
	local info = self.agent_info or {}
	return one_line(info.title or info.name or self.s.agent)
end

function Chat:model_title()
	local _, name = models.current(self)
	return name and one_line(name) or nil
end

function Chat:mode_title()
	local _, name = modes.current(self)
	return name and one_line(name) or nil
end

function Chat:accept_settings(response)
	local previous_mode = modes.current(self)
	models.accept(self, response)
	modes.accept(self, response, previous_mode)
end

local function truncate(text, max)
	return vim.fn.strchars(text) > max and vim.fn.strcharpart(text, 0, max - 1) .. "…" or text
end

--- What the agent is doing right now, e.g. "thinking" or a running tool's title, with the
--- turn's elapsed time; nil when it's idle.
function Chat:activity()
	if self.state == "starting" then
		return "starting…"
	elseif self.model_pending then
		return self.model_pending
	elseif self.mode_pending then
		return self.mode_pending
	elseif not self.busy then
		return nil
	end
	local what
	if self.permission then
		what = "waiting for your permission"
	else
		local d = self.doing or {}
		local tool = d.kind == "tool" and self.tools[d.id]
		if tool then
			what = truncate(one_line(tool.title or "running a tool"), 60)
		elseif d.kind == "writing" then
			what = "writing"
		elseif d.kind == "thinking" then
			what = "thinking"
		else
			what = "working"
		end
	end
	return what .. (self.turn_started and " · " .. spinner.elapsed(self.turn_started) or "")
end

function Chat:build_lines()
	return transcript.build_lines(self)
end

--- Advance the typewriter reveal of streamed text by one frame. Each frame shows a fraction of
--- the unrevealed backlog, so bursty chunks flow in evenly and a large backlog catches up fast.
--- Returns true while there is text left to reveal.
function Chat:advance(instant)
	return transcript.advance(self, instant)
end

function Chat:render()
	return require("aero.acp.transcript").render(self)
end

--- Color the pending permission options by kind and mark the one under the cursor.
function Chat:decorate_options()
	return transcript.decorate_options(self)
end

function Chat:mark_selected()
	return transcript.mark_selected(self)
end

--- First and last line of the pending permission's options, if any.
function Chat:option_range(block)
	return transcript.option_range(self, block)
end

--- Move the transcript's cursor to the pending permission's options. With `focus`, also put
--- the cursor in the transcript window (opening it if needed is the caller's job).
function Chat:goto_permission(focus, block)
	return transcript.goto_permission(self, focus, block)
end

--- Reveal an inbox event after the deferred transcript render has settled.
function Chat:goto_block(block, permission)
	return transcript.goto_block(self, block, permission)
end

function Chat:changed()
	self:save_history()
	self:render()
	require("aero.session").emit()
end

function Chat:save_history()
	if self.replaying or chats_by_key[self.s.key] ~= self then
		return
	end
	history.save(self.s, function()
		return require("aero.acp.projection").history(self)
	end)
end

function Chat:append(kind, text)
	local b = self.blocks[#self.blocks]
	if b and b.kind == kind and not b.image then
		b.text = b.text .. text
	else
		b = { kind = kind, text = text, timestamp = not self.replaying and os.time() or nil }
		table.insert(self.blocks, b)
	end
	-- live agent output is revealed gradually; replayed history appears at once
	if (kind == "agent" or kind == "thought") and not self.replaying and not b.shown then
		b.shown = #b.text - #text
		table.insert(self.revealing, b)
	end
end

function Chat:append_content(kind, content)
	if type(content) == "table" and content.type == "image" then
		table.insert(self.blocks, {
			kind = kind,
			text = "[image]",
			image = vim.deepcopy(content),
			timestamp = not self.replaying and os.time() or nil,
		})
	else
		self:append(kind, content_text(content))
	end
end

function Chat:info(text, kind)
	local block = { kind = "info", text = text, meta_kind = kind, timestamp = not self.replaying and os.time() or nil }
	table.insert(self.blocks, block)
	if kind == "error" then
		require("aero.inbox").add(self, "error", block)
	end
end

---------------------------------------------------------------------------
-- Protocol handlers
---------------------------------------------------------------------------

function Chat:on_update(u)
	return require("aero.acp.updates").apply(self, u)
end

function Chat:on_request(method, params, respond)
	return require("aero.acp.requests").handle(self, method, params, respond)
end

--- Jump to the pending permission request's options in the transcript.
function Chat:answer_permission()
	if not self.permission then
		vim.notify("Aero: no pending permission request")
		return
	end
	self:goto_permission(true)
end

--- Answer the pending permission request with option `index`.
function Chat:choose(index, block)
	local p = self.permission
	if block then
		p = nil
		for _, request in ipairs(self.permissions or {}) do
			if request.block == block then
				p = request
				break
			end
		end
	end
	local choice = p and p.block.options[index]
	if not choice then
		return
	end
	for i, request in ipairs(self.permissions or {}) do
		if request == p then
			table.remove(self.permissions, i)
			break
		end
	end
	self.permission = self.permissions and self.permissions[1]
	self:set_option_keys(self.permission ~= nil)
	self.pending_focus = self.permission ~= nil
	p.block.answer = choice.name or choice.optionId
	if choice.auto_yes then
		self.auto_yes = true
	end
	p.respond({ outcome = { outcome = "selected", optionId = choice.auto_yes or choice.optionId } })
	if choice.auto_yes then
		for _, request in ipairs(vim.list_extend({}, self.permissions or {})) do
			for i, option in ipairs(request.block.options) do
				if option.auto_yes then
					self:choose(i, request.block)
					break
				end
			end
		end
	end
	-- back to following the output
	for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
		api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(self.buf), 0 })
	end
	self:changed()
end

function Chat:toggle_auto_yes()
	self.auto_yes = not self.auto_yes
	if self.auto_yes then
		for _, request in ipairs(vim.list_extend({}, self.permissions or {})) do
			for i, option in ipairs(request.block.options) do
				if option.auto_yes then
					self:choose(i, request.block)
					break
				end
			end
		end
	end
	vim.notify("Aero: auto yes " .. (self.auto_yes and "enabled" or "disabled") .. " for this conversation")
end

--- <CR> in the transcript: choose the option under the cursor, otherwise write a prompt.
function Chat:enter_key()
	local o = self.permission and (self.option_lines or {})[api.nvim_win_get_cursor(0)[1]]
	if o then
		return self:choose(o.index, o.block)
	end
	self:compose()
end

--- While a request is pending, the number keys choose an option directly.
function Chat:set_option_keys(on)
	local buf = self.buf
	for i = 1, 9 do
		local lhs = tostring(i)
		local available = false
		for _, request in ipairs(self.permissions or {}) do
			available = available or request.block.options[i] ~= nil
		end
		if on and available then
			vim.keymap.set("n", lhs, function()
				local o = (self.option_lines or {})[api.nvim_win_get_cursor(0)[1]]
				self:choose(i, o and o.block)
			end, { buffer = buf, nowait = true, desc = "Aero: choose permission option " .. i })
		else
			pcall(vim.keymap.del, "n", lhs, { buffer = buf })
		end
	end
end

---------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------

function Chat:status()
	if self.state == "exited" then
		return "exited"
	elseif self.permission then
		return "waiting"
	elseif self.busy or self.model_pending or self.mode_pending or self.task_pending or self.state == "starting" then
		return "busy"
	end
	return "idle"
end

function Chat:alive()
	return self.state ~= "exited"
end

function Chat:ready(session_id, response)
	self.session_id = session_id
	self.state = "ready"
	store.set_session_field(self.s.worktree, self.s.name, "acp_session_id", session_id)
	self:accept_settings(response)
	self:changed()
	events.emit(
		"session_ready",
		events.session(self.s, { session_id = session_id, resumed = self.resumed == true, type = "acp" })
	)
	if self.on_resume then
		local callback = self.on_resume
		self.on_resume = nil
		callback(self)
	end
	if self.state ~= "ready" then
		return
	end
	self:flush_queue()
end

function Chat:fail(what, err)
	self:info(("%s failed: %s"):format(what, error_text(err)), "error")
	self:changed()
end

function Chat:resume_failed(session_id, err)
	self.resume_error = err
	self.state, self.busy = "exited", false
	self:info(
		"could not resume session "
			.. session_id
			.. ": "
			.. error_text(err)
			.. "\nSaved session kept; press r in the dashboard to retry.",
		"error"
	)
	self:changed()
	self:stop()
	events.emit("session_resume_failed", events.session(self.s, { session_id = session_id, type = "acp", error = err }))
	if self.on_resume then
		local callback = self.on_resume
		self.on_resume = nil
		callback(self, err)
	end
end

function Chat:handshake(resume)
	self.client:request("initialize", {
		protocolVersion = 1,
		clientCapabilities = { fs = { readTextFile = true, writeTextFile = true }, terminal = false },
		clientInfo = { name = "Aero.nvim", title = "Aero.nvim", version = "0.1.0" },
	}, function(err, res)
		if err then
			if self.requested_session_id then
				return self:resume_failed(self.requested_session_id, err)
			end
			return self:fail("initialize", err)
		end
		self.agent_info = res.agentInfo
		self.caps = res.agentCapabilities or {}
		store.load()
		local def = store.find_session(self.s.worktree, self.s.name) or {}
		local previous_id = def.acp_session_id or self.saved_session_id
		local session_id = self.requested_session_id or previous_id
		self.saved_session_id = self.cache_session_id or previous_id or session_id
		local base = { cwd = self.s.worktree, mcpServers = self.s.mcp_servers or {} }
		if resume and session_id and self.caps.loadSession then
			-- Cached errors are not conversation history. A different selected ID must
			-- replay its own transcript, without relabeling the previous conversation.
			self.replay_from_cache = self.restored_conversation
				and (not self.cache_session_id or self.cache_session_id == session_id)
			local previous_blocks, previous_tools, previous_usage = self.blocks, self.tools, self.usage
			if
				(self.requested_session_id and self.requested_session_id ~= previous_id)
				or (self.cache_session_id and self.cache_session_id ~= session_id)
			then
				self.blocks, self.tools = {}, {}
				self.usage = nil
				self.replay_from_cache = false
			end
			self.replaying = true
			self.client:request(
				"session/load",
				vim.tbl_extend("force", base, { sessionId = session_id }),
				function(lerr, response)
					self.replaying = false
					if not lerr then
						self.resumed = true
						self:info("resumed session", "session")
						return self:ready(session_id, response)
					end
					-- A transient adapter failure must not replace the original conversation ID.
					self.blocks, self.tools = previous_blocks, previous_tools
					self.usage = previous_usage
					self:resume_failed(session_id, lerr)
				end
			)
		else
			if self.requested_session_id then
				return self:resume_failed(
					session_id,
					{ code = -32601, message = "agent does not advertise session/load support" }
				)
			end
			if resume and self.restored_history then
				local reason = not session_id and "no saved ACP session ID"
					or "agent does not advertise session/load support"
				self:info("saved log restored; could not resume (" .. reason .. "), starting a new session")
			end
			self:new_session(base)
		end
	end)
end

function Chat:new_session(params)
	self.resumed = false
	self.usage = nil
	self.usage_seen = nil
	self.client:request("session/new", params, function(err, res)
		if err then
			return self:fail("session/new", err)
		end
		self:ready(res.sessionId, res)
	end)
end

function Chat:prompt(text)
	if vim.trim(text) == "/export" then
		return require("aero.exports").export(self)
	end
	if self.state == "exited" then
		local message = self.resume_error and "Aero: session could not be resumed; retry with r in the dashboard"
			or "Aero: agent has exited; restart it with r in the dashboard"
		vim.notify(message, vim.log.levels.WARN)
		return
	end
	if vim.trim(text) == "/report" then
		return require("aero.reports").pick(self.s)
	end
	if vim.trim(text) == "/cancel" then
		return self:cancel()
	end
	if self.task_pending then
		table.insert(self.queue, text)
		return self:changed()
	end
	if vim.trim(text):match("^/new%-ticket%s") or vim.trim(text) == "/new-ticket" then
		if not self.s.task_binding then
			if self.state ~= "ready" or self.busy or self.model_pending or self.mode_pending then
				table.insert(self.queue, text)
				return self:changed()
			end
			return require("aero.tasks.agent").prepare_new_ticket(self, function()
				self:prompt(text)
			end)
		end
	end
	local expanded, expansion_err = require("aero.tasks.agent").expand_new_ticket(self.s, text)
	if not expanded then
		vim.notify("Aero: " .. expansion_err, vim.log.levels.WARN)
		return
	end
	text = expanded
	-- queued prompts are shown at the end of the transcript and only become blocks once sent,
	-- so a resumed session's replayed history (or a failed resume) can't bury or drop them
	if self.state ~= "ready" or self.busy or self.model_pending or self.mode_pending then
		table.insert(self.queue, text)
		return self:changed()
	end
	if models.handle(self, text) or modes.handle(self, text) then
		return
	end
	local prompt_block = { kind = "user", text = text, timestamp = os.time() }
	table.insert(self.blocks, prompt_block)
	self.turn = (self.turn or 0) + 1
	local turn = self.turn
	self.busy = true
	self.turn_started, self.doing = vim.uv.now(), nil
	self:changed()
	spinner.ensure()
	self.client:request("session/prompt", {
		sessionId = self.session_id,
		prompt = { { type = "text", text = text } },
	}, function(err, res)
		self.busy = false
		usage.response(self, res, turn)
		if err then
			self:fail("prompt", err)
		elseif res and res.stopReason and res.stopReason ~= "end_turn" then
			self:info("stopped: " .. res.stopReason)
		else
			require("aero.inbox").add(self, "completed", prompt_block, "Turn completed")
		end
		self:changed()
		self:flush_queue()
	end)
end

--- Send the next queued prompt, if any.
function Chat:flush_queue()
	local text = table.remove(self.queue, 1)
	if text then
		self:prompt(text)
	end
end

function Chat:cancel()
	self.queue = {}
	self.pending_focus = false
	if self.permission then
		local pending = self.permissions or { self.permission }
		self.permissions = {}
		self.permission = nil
		self:set_option_keys(false)
		for _, p in ipairs(pending) do
			p.block.answer = "cancelled"
			p.respond({ outcome = { outcome = "cancelled" } })
		end
	end
	if self.busy and self.session_id then
		self.client:notify("session/cancel", { sessionId = self.session_id })
	end
	self:changed()
end

function Chat:stop()
	self:save_history()
	history.flush(self.s)
	if self.client then
		self.client:stop()
	end
end

---------------------------------------------------------------------------
-- Prompt buffer
---------------------------------------------------------------------------

function Chat:send_prompt_buf()
	return require("aero.acp.prompt").send(self)
end

function Chat:get_prompt_buf()
	return require("aero.acp.prompt").buffer(self, function(key)
		return chats_by_key[key]
	end)
end

--- Toggle this tab's prompt windows without discarding the draft.
function Chat:toggle_prompt()
	return require("aero.acp.prompt").toggle(self)
end

--- Open the prompt window below the transcript and start insert mode.
function Chat:compose()
	return require("aero.acp.prompt").compose(self)
end

---------------------------------------------------------------------------
-- Session backend interface (used by Aero.session)
---------------------------------------------------------------------------

local function setup_transcript(chat)
	return require("aero.acp.transcript").setup(chat)
end

---@param s Aero.Session
---@param buf integer transcript buffer (already shown in a window)
---@param agent Aero.Agent
---@param resume boolean
---@param session_id? string explicit conversation ID for recovery
---@return Aero.acp.Chat|nil
function M.start(s, buf, agent, resume, session_id, opts)
	opts = opts or {}
	local chat = setmetatable({
		s = s,
		buf = buf,
		state = "starting",
		busy = false,
		auto_yes = require("aero.config").options.acp.auto_yes == true,
		blocks = {},
		tools = {},
		queue = {},
		revealing = {},
		requested_session_id = session_id,
		on_resume = opts.on_resume,
		task_pending = opts.on_resume ~= nil,
	}, Chat)
	local old = chats_by_key[s.key]
	local saved = resume and history.load(s)
	if saved and saved.type == "acp" and type(saved.blocks) == "table" then
		chat.blocks, chat.agent_info = saved.blocks, saved.agent_info
		usage.restore(chat, saved.usage)
		chat.saved_session_id = type(saved.session_id) == "string" and saved.session_id ~= "" and saved.session_id
			or nil
		chat.cache_session_id = chat.saved_session_id
		chat.restored_history = #chat.blocks > 0
		for _, b in ipairs(chat.blocks) do
			if b.kind ~= "info" then
				chat.restored_conversation = true
			end
			if b.kind == "tool" and b.id then
				chat.tools[b.id] = b
			end
		end
	end
	if old then
		chat.prompt_buf = old.prompt_buf
		if resume and old.resume_error then
			chat.queue = old.queue
		end
	end
	chats_by_key[s.key] = chat
	setup_transcript(chat)
	local cmd = type(agent.cmd) == "function" and agent.cmd(s) or agent.cmd
	local client, err = Client.spawn(cmd, {
		cwd = s.worktree,
		env = vim.tbl_extend("force", agent.env or {}, s.runtime_env or {}),
		on_request = function(method, params, respond)
			chat:on_request(method, params, respond)
		end,
		on_notification = function(method, params)
			if method == "session/update" and params.update then
				chat:on_update(params.update)
			end
		end,
		on_exit = function(code, stderr)
			chat.state, chat.busy, chat.permission = "exited", false, nil
			chat.permissions = {}
			chat.model_pending = nil
			chat.mode_pending = nil
			chat:set_option_keys(false)
			chat.exit_code = code
			local msg = ("agent exited (%d)"):format(code)
			stderr = vim.trim(stderr or "")
			if code ~= 0 and stderr ~= "" then
				msg = msg .. ": " .. stderr:sub(-500)
			end
			if not chat.resume_error then
				chat:info(msg, code == 0 and "session" or "error")
			elseif stderr ~= "" then
				chat:info("adapter stderr: " .. stderr:sub(-2000), code == 0 and "session" or "error")
			end
			chat:changed()
			if chats_by_key[s.key] == chat then
				events.emit("session_exited", events.session(s, { exit_code = code, type = "acp" }))
			end
		end,
	})
	if not client then
		vim.notify(("Aero: failed to start %s: %s"):format(table.concat(cmd, " "), err), vim.log.levels.ERROR)
		return nil
	end
	chat.client = client
	chat:render()
	spinner.ensure()
	chat:handshake(resume)
	return chat
end

--- Toggle the input for a session, or the currently focused Aero buffer.
function M.toggle_prompt(s)
	local key = s and s.key or vim.b.aero_chat_key or vim.b.aero_session
	local chat = key and chats_by_key[key]
	if chat then
		chat:toggle_prompt()
	end
end

function M.compose(s)
	local chat = chats_by_key[s.key]
	if chat then
		chat:compose()
	end
end

function M.forget(s)
	local chat = chats_by_key[s.key]
	if chat then
		chat:stop()
		if chat.prompt_buf and api.nvim_buf_is_valid(chat.prompt_buf) then
			api.nvim_buf_delete(chat.prompt_buf, { force = true })
		end
		chats_by_key[s.key] = nil
	end
end

function M.omnifunc(findstart, base)
	local chat = chats_by_key[vim.b.aero_chat_key or ""]
	local line = api.nvim_get_current_line():sub(1, api.nvim_win_get_cursor(0)[2])
	local prefix = line:match("^(%s*/model%s+)") or line:match("^(%s*/mode%s+)")
	local selector = prefix and (prefix:match("/model%s") and models or modes)
	if findstart == 1 then
		if prefix then
			return #prefix
		end
		local start = line:find("/[%w%-_]*$")
		return start and start - 1 or -3
	end
	local out = {}
	if not prefix and ("/export"):sub(1, #base) == base then
		table.insert(out, { word = "/export", menu = "Save this conversation as Markdown" })
	end
	if prefix then
		for _, choice in ipairs(selector.options(chat).choices) do
			if choice.id:sub(1, #base) == base then
				table.insert(
					out,
					{ word = choice.id, abbr = choice.name, menu = choice.group or choice.description or "" }
				)
			end
		end
		return out
	end
	if ("/model"):sub(1, #base) == base then
		table.insert(out, { word = "/model", menu = "Choose the session's AI model" })
	end
	if ("/mode"):sub(1, #base) == base then
		table.insert(out, { word = "/mode", menu = "Choose the session mode" })
	end
	if ("/report"):sub(1, #base) == base then
		table.insert(out, { word = "/report", menu = "Attach a worktree report to the draft" })
	end
	if ("/cancel"):sub(1, #base) == base then
		table.insert(out, { word = "/cancel", menu = "Cancel the current turn and discard queued prompts" })
	end
	if ("/new-ticket"):sub(1, #base) == base then
		table.insert(out, { word = "/new-ticket", menu = "Create an Aero ticket with initial content through MCP" })
	end
	for _, c in ipairs(chat and chat.commands or {}) do
		local word = "/" .. c.name
		if
			word ~= "/model"
			and word ~= "/export"
			and word ~= "/mode"
			and word ~= "/report"
			and word ~= "/cancel"
			and word ~= "/new-ticket"
			and word:find(base, 1, true) == 1
		then
			table.insert(out, { word = word, menu = c.description })
		end
	end
	return out
end

-- keep the footer and running tool calls of busy transcripts spinning
spinner.on_frame(function()
	local any = false
	for _, chat in pairs(chats_by_key) do
		if
			(chat.busy or chat.model_pending or chat.mode_pending or chat.state == "starting")
			and api.nvim_buf_is_valid(chat.buf)
		then
			any = true
			if vim.fn.bufwinid(chat.buf) ~= -1 then
				chat:render()
			end
		end
	end
	return any
end)

return M
