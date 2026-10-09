-- ACP-backed agent sessions: the transcript is a read-only markdown buffer,
-- prompts are written in a regular buffer and sent with :w / <C-s>.
local config = require("aero.config")
local store = require("aero.store")
local Client = require("aero.acp.client")
local spinner = require("aero.spinner")
local history = require("aero.history")
local events = require("aero.events")
local models = require("aero.acp.models")
local modes = require("aero.acp.modes")
local renderer = require("aero.acp.render")
local usage = require("aero.acp.usage")

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

local function split(text)
	return vim.split(text, "\n", { plain = true })
end

--- Agent-provided text shown on a single line (titles, option names, …) may contain newlines,
--- e.g. a multi-line shell command as a tool title; buffer lines can't.
local function one_line(text)
	return (tostring(text or ""):gsub("%s*\r?\n%s*", " ⏎ "))
end

--- Window-local options for chat buffers (transcript and prompt). Folding is off so that a
--- config that folds markdown headers by default doesn't collapse the conversation.
local function chat_win_opts(win, extra)
	local opts = vim.tbl_extend("force", { foldenable = false, number = false, relativenumber = false }, extra or {})
	for k, v in pairs(opts) do
		api.nvim_set_option_value(k, v, { win = win, scope = "local" })
	end
end

local transcript_win_opts = { wrap = true, linebreak = true, conceallevel = 2 }

--- Set `buf`'s filetype from inside a window showing it, so FileType handlers (which set
--- window options such as folds) act on that window rather than whichever one is current.
local function set_filetype(buf, ft)
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		api.nvim_win_call(win, function()
			vim.bo[buf].filetype = ft
		end)
	else
		vim.bo[buf].filetype = ft
	end
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
	local lines, marks, options, blocks = renderer.build(self)
	self.render_marks, self.option_lines, self.block_lines = marks, options, blocks
	return lines
end

--- Advance the typewriter reveal of streamed text by one frame. Each frame shows a fraction of
--- the unrevealed backlog, so bursty chunks flow in evenly and a large backlog catches up fast.
--- Returns true while there is text left to reveal.
function Chat:advance(instant)
	local left = {}
	for _, b in ipairs(self.revealing) do
		local text = b.text
		local n = instant and #text or math.min(#text, b.shown + math.max(3, math.ceil((#text - b.shown) / 8)))
		-- don't cut a multibyte character in half
		while n < #text and text:byte(n + 1) >= 0x80 and text:byte(n + 1) < 0xC0 do
			n = n + 1
		end
		if n >= #text then
			b.shown = nil
		else
			b.shown = n
			table.insert(left, b)
		end
	end
	self.revealing = left
	return #left > 0
end

function Chat:render()
	if self.render_pending then
		return
	end
	self.render_pending = true
	vim.defer_fn(function()
		self.render_pending = false
		local buf = self.buf
		if not api.nvim_buf_is_valid(buf) then
			return
		end
		-- animate only while someone is watching
		if self:advance(vim.fn.bufwinid(buf) == -1) then
			self:render()
		end
		-- windows whose cursor is on the last line keep following the output
		local follow = {}
		local last = api.nvim_buf_line_count(buf)
		for _, win in ipairs(vim.fn.win_findbuf(buf)) do
			if api.nvim_win_get_cursor(win)[1] >= last then
				table.insert(follow, win)
			end
		end
		-- only replace the lines that changed (usually the tail of the streaming block), so the
		-- rest of the buffer, its highlighting and the windows' views stay untouched
		local old, new = self.lines, self:build_lines()
		require("aero.acp.todos").update(self)
		if not old or #old ~= api.nvim_buf_line_count(buf) then
			-- no record of the buffer, or it's out of sync: diff against what's really there
			old = api.nvim_buf_get_lines(buf, 0, -1, false)
		end
		local first = 1
		while first <= #old and first <= #new and old[first] == new[first] do
			first = first + 1
		end
		if first > #old and first > #new then
			self.lines = new
			renderer.decorate(buf, new, self.render_marks)
			self:decorate_options()
			return
		end
		local old_last, new_last = #old, #new
		while old_last >= first and new_last >= first and old[old_last] == new[new_last] do
			old_last, new_last = old_last - 1, new_last - 1
		end
		vim.bo[buf].modifiable = true
		local ok, err =
			pcall(api.nvim_buf_set_lines, buf, first - 1, old_last, false, vim.list_slice(new, first, new_last))
		vim.bo[buf].modifiable = false
		vim.bo[buf].modified = false
		if not ok then
			-- keep the record matching the buffer, so the next render repairs it instead of drifting
			self.lines = nil
			vim.notify("Aero: failed to render transcript: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		self.lines = new
		renderer.decorate(buf, new, self.render_marks, first)
		for _, win in ipairs(follow) do
			api.nvim_win_set_cursor(win, { #new, 0 })
		end
		self:decorate_options()
		if self.pending_focus then
			self.pending_focus = false
			self:goto_permission(false)
		end
	end, 16)
end

local option_ns = api.nvim_create_namespace("Aero.acp.options")
local select_ns = api.nvim_create_namespace("Aero.acp.option_select")
local option_hl = {
	allow_once = "DiagnosticOk",
	allow_always = "DiagnosticOk",
	reject_once = "DiagnosticError",
	reject_always = "DiagnosticError",
}

--- Color the pending permission options by kind and mark the one under the cursor.
function Chat:decorate_options()
	local buf = self.buf
	api.nvim_buf_clear_namespace(buf, option_ns, 0, -1)
	for lnum, o in pairs(self.option_lines or {}) do
		local line = self.lines[lnum]
		api.nvim_buf_set_extmark(
			buf,
			option_ns,
			lnum - 1,
			2,
			{ end_col = #line, hl_group = option_hl[o.kind] or "Normal" }
		)
	end
	self:mark_selected()
end

function Chat:mark_selected()
	local buf = self.buf
	api.nvim_buf_clear_namespace(buf, select_ns, 0, -1)
	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		return
	end
	if api.nvim_get_current_buf() == buf then
		win = api.nvim_get_current_win()
	end
	local lnum = api.nvim_win_get_cursor(win)[1]
	if (self.option_lines or {})[lnum] then
		api.nvim_buf_set_extmark(buf, select_ns, lnum - 1, 0, {
			virt_text = { { "▸", "Special" } },
			virt_text_pos = "overlay",
			line_hl_group = "CursorLine",
		})
	end
end

--- First and last line of the pending permission's options, if any.
function Chat:option_range()
	local first, last
	for lnum in pairs(self.option_lines or {}) do
		first = (not first or lnum < first) and lnum or first
		last = (not last or lnum > last) and lnum or last
	end
	return first, last
end

--- Scroll `win` so the whole pending request (header, options, hint) is visible, with the
--- cursor on its first option. If it doesn't fit, the window scrolls back to the first option.
local function reveal_request(win, first, last, line_count)
	api.nvim_win_call(win, function()
		-- put the hint line (two below the last option) at the bottom of the window
		api.nvim_win_set_cursor(win, { math.min(last + 2, line_count), 0 })
		vim.cmd("normal! zb")
		api.nvim_win_set_cursor(win, { first, 0 })
	end)
end

--- Move the transcript's cursor to the pending permission's options. With `focus`, also put
--- the cursor in the transcript window (opening it if needed is the caller's job).
function Chat:goto_permission(focus)
	local first, last = self:option_range()
	if not first then
		return false
	end
	local tab = api.nvim_get_current_tabpage()
	local count = api.nvim_buf_line_count(self.buf)
	for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
		reveal_request(win, first, last, count)
		if focus and api.nvim_win_get_tabpage(win) == tab then
			api.nvim_set_current_win(win)
			vim.cmd.stopinsert()
			focus = false
		end
	end
	self:mark_selected()
	return true
end

--- Reveal an inbox event after the deferred transcript render has settled.
function Chat:goto_block(block, permission)
	self:advance(true)
	self:render()
	vim.defer_fn(function()
		if not api.nvim_buf_is_valid(self.buf) then
			return
		end
		if permission then
			if self.permission and self.permission.block == block then
				self:goto_permission(true)
			end
			return
		end
		local row = self.block_lines and self.block_lines[block]
		for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
			if api.nvim_win_get_tabpage(win) == api.nvim_get_current_tabpage() then
				api.nvim_win_set_cursor(win, { math.min(row or 1, api.nvim_buf_line_count(self.buf)), 0 })
				api.nvim_win_call(win, function()
					vim.cmd("normal! zz")
				end)
			end
		end
	end, 32)
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
		-- Persist protocol data, not typewriter/render caches or live permission callbacks.
		local blocks = {}
		for _, block in ipairs(self.blocks) do
			local b = vim.deepcopy(block)
			b.cache, b.cache_src, b.shown = nil, nil, nil
			if b.kind == "permission" and not b.answer then
				b.answer = "interrupted"
			end
			table.insert(blocks, b)
		end
		return {
			type = "acp",
			blocks = blocks,
			agent_info = self.agent_info,
			session_id = self.session_id or self.saved_session_id,
			usage = self.usage,
		}
	end)
end

function Chat:append(kind, text)
	local b = self.blocks[#self.blocks]
	if b and b.kind == kind then
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
	-- Ticket reassignment reloads the same conversation, not a new history/settings
	-- snapshot. Ignore its replay (including historical usage and setting changes).
	if self.task_reloading then
		return
	end
	local kind = u.sessionUpdate
	if kind == "plan" or kind == "tool_call" or kind == "tool_call_update" then
		self.todo_notification_snapshot = vim.deepcopy(require("aero.acp.todos").latest(self))
	end
	-- The local transcript already contains the history replayed by session/load.
	if
		self.replaying
		and self.replay_from_cache
		and kind ~= "available_commands_update"
		and kind ~= "current_mode_update"
		and kind ~= "config_option_update"
		and kind ~= "current_model_update"
		and kind ~= "usage_update"
	then
		return
	end
	if kind == "user_message_chunk" then
		self:append("user", content_text(u.content))
	elseif kind == "agent_message_chunk" then
		self:append("agent", content_text(u.content))
		self.doing = { kind = "writing" }
	elseif kind == "agent_thought_chunk" then
		self:append("thought", content_text(u.content))
		self.doing = { kind = "thinking" }
	elseif kind == "tool_call" or kind == "tool_call_update" then
		-- the latest tool call is what the agent is doing, until it finishes
		if u.status == "completed" or u.status == "failed" then
			if self.doing and self.doing.id == u.toolCallId then
				self.doing = { kind = "thinking" }
			end
		else
			self.doing = { kind = "tool", id = u.toolCallId }
		end
		local b = self.tools[u.toolCallId]
		if not b then
			b = { kind = "tool", id = u.toolCallId, timestamp = not self.replaying and os.time() or nil }
			self.tools[u.toolCallId] = b
			table.insert(self.blocks, b)
		end
		for _, field in ipairs({ "title", "status", "content", "locations", "rawInput", "rawOutput" }) do
			if u[field] ~= nil then
				b[field] = u[field]
			end
		end
		b.tool_kind = u.kind or b.tool_kind
	elseif kind == "plan" then
		-- one plan block per turn, updated in place
		if self.plan and self.plan.turn == self.turn then
			self.plan.entries = u.entries
		else
			self.plan = { kind = "plan", entries = u.entries, turn = self.turn, timestamp = not self.replaying and os.time() or nil }
			table.insert(self.blocks, self.plan)
		end
	elseif kind == "available_commands_update" then
		self.commands = u.availableCommands
	elseif kind == "current_mode_update" then
		self:accept_settings(u)
		return self:changed()
	elseif kind == "config_option_update" then
		self:accept_settings(u)
		return self:changed()
	elseif kind == "current_model_update" then
		self:accept_settings(u)
		return self:changed()
	elseif kind == "usage_update" then
		usage.update(self, u)
		return self:changed()
	else
		return
	end
	if kind == "plan" or kind == "tool_call" or kind == "tool_call_update" then
		require("aero.acp.todo_notifications").update(self)
	end
	self:save_history()
	self:render()
end

local function read_file(path, line, limit)
	local bufnr = vim.fn.bufnr(path)
	local lines
	if bufnr > 0 and api.nvim_buf_is_loaded(bufnr) then
		lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
	else
		local ok, res = pcall(vim.fn.readfile, path)
		if not ok then
			return nil, res
		end
		lines = res
	end
	local first = line or 1
	local last = limit and (first + limit - 1) or #lines
	return table.concat(vim.list_slice(lines, first, last), "\n")
end

local function write_file(path, content)
	local lines = split(content)
	local bufnr = vim.fn.bufnr(path)
	if bufnr > 0 and api.nvim_buf_is_loaded(bufnr) then
		api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		local ok, err = pcall(api.nvim_buf_call, bufnr, function()
			vim.cmd("silent noautocmd write!")
		end)
		return ok, err
	end
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local ok, err = pcall(vim.fn.writefile, lines, path)
	vim.schedule(function()
		vim.cmd("checktime")
	end)
	return ok, err
end

function Chat:on_request(method, params, respond)
	if method == "fs/read_text_file" then
		local content, err = read_file(params.path, params.line, params.limit)
		if content then
			respond({ content = content })
		else
			respond(nil, { code = -32603, message = tostring(err) })
		end
	elseif method == "fs/write_text_file" then
		local path = require("aero.storage").canonical(params.path)
		for _, document in ipairs(self.s.task_documents or {}) do
			if path == document then
				respond(nil, {
					code = -32603,
					message = "Assigned task documents must be updated through Aero task tools, using their expected revisions.",
				})
				return
			end
		end
		local ok, err = write_file(params.path, params.content or "")
		if ok then
			respond(vim.NIL)
		else
			respond(nil, { code = -32603, message = tostring(err) })
		end
	elseif method == "session/request_permission" then
		local tool = params.toolCall or {}
		local known = self.tools[tool.toolCallId]
		local block = {
			kind = "permission",
			timestamp = os.time(),
			title = tool.title or (known and known.title) or "tool call",
			options = params.options or {},
		}
		table.insert(self.blocks, block)
		self.permission = { params = params, respond = respond, block = block }
		require("aero.inbox").add(self, "permission", block)
		self:set_option_keys(true)
		-- the agent is blocked on this: show the text still being revealed at once, so nothing moves
		-- the request after its options are scrolled into view
		self:advance(true)
		-- the options are listed in the transcript; point its cursor at them once rendered, and only
		-- grab focus if the user is already in the transcript
		self.pending_focus = true
		self:changed()
		if api.nvim_get_current_buf() ~= self.buf then
			vim.notify(
				("Aero: %s in %s needs permission: %s (choose in the agent log, or :Aero prompt)"):format(
					self.s.name,
					vim.fn.fnamemodify(self.s.worktree, ":~"),
					block.title
				)
			)
		end
	else
		respond(nil, { code = -32601, message = "method not supported: " .. method })
	end
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
function Chat:choose(index)
	local p = self.permission
	local choice = p and p.block.options[index]
	if not choice then
		return
	end
	self.permission = nil
	self:set_option_keys(false)
	p.block.answer = choice.name or choice.optionId
	p.respond({ outcome = { outcome = "selected", optionId = choice.optionId } })
	-- back to following the output
	for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
		api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(self.buf), 0 })
	end
	self:changed()
end

--- <CR> in the transcript: choose the option under the cursor, otherwise write a prompt.
function Chat:enter_key()
	local o = self.permission and (self.option_lines or {})[api.nvim_win_get_cursor(0)[1]]
	if o then
		return self:choose(o.index)
	end
	self:compose()
end

--- While a request is pending, the number keys choose an option directly.
function Chat:set_option_keys(on)
	local buf = self.buf
	for i = 1, 9 do
		local lhs = tostring(i)
		if on and self.permission and self.permission.block.options[i] then
			vim.keymap.set("n", lhs, function()
				self:choose(i)
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
		local p = self.permission
		self.permission = nil
		self:set_option_keys(false)
		p.block.answer = "cancelled"
		p.respond({ outcome = { outcome = "cancelled" } })
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
	local buf = self.prompt_buf
	if not (buf and api.nvim_buf_is_valid(buf)) then
		return
	end
	local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
	if text == "" then
		vim.bo[buf].modified = false
		return
	end
	if self.state == "exited" and text ~= "/export" then
		-- Report the failed backend without clearing a prompt that cannot be sent.
		return self:prompt(text)
	end
	if not self.s.task_binding and (text:match("^/new%-ticket%s") or text == "/new-ticket") then
		return require("aero.tasks.agent").prepare_new_ticket(self, function()
			self:send_prompt_buf()
		end)
	end
	local expanded, expansion_err = require("aero.tasks.agent").expand_new_ticket(self.s, text)
	if not expanded then
		vim.notify("Aero: " .. expansion_err, vim.log.levels.WARN)
		return
	end
	api.nvim_buf_set_lines(buf, 0, -1, false, {})
	vim.bo[buf].modified = false
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		api.nvim_win_close(win, true)
	end
	vim.cmd.stopinsert()
	-- make the transcript follow the new turn
	for _, win in ipairs(vim.fn.win_findbuf(self.buf)) do
		api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(self.buf), 0 })
	end
	self:prompt(expanded)
end

function Chat:get_prompt_buf()
	if self.prompt_buf and api.nvim_buf_is_valid(self.prompt_buf) then
		return self.prompt_buf
	end
	local buf = api.nvim_create_buf(false, true)
	self.prompt_buf = buf
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	pcall(api.nvim_buf_set_name, buf, ("Aero://%s#%s/prompt"):format(self.s.worktree, self.s.name))
	-- the filetype is set once the buffer is shown (see compose), in its own window
	-- the prompt buffer outlives restarts, so always act on the session's current chat
	local key = self.s.key
	local function with_chat(method)
		return function()
			local chat = chats_by_key[key]
			if chat then
				chat[method](chat)
			end
		end
	end
	api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = with_chat("send_prompt_buf") })
	local function map(mode, lhs, fn, desc)
		vim.keymap.set(mode, lhs, fn, { buffer = buf, nowait = true, desc = "Aero: " .. desc })
	end
	map({ "n", "i" }, "<C-s>", with_chat("send_prompt_buf"), "send prompt")
	local resize_keys = require("aero.layout").keys(true)
	-- Allow a customized Ctrl-s resize prefix while keeping the default send immediate.
	local send_key = api.nvim_replace_termcodes("<C-s>", true, false, true)
	for _, name in ipairs({ "grow", "shrink", "narrow", "widen" }) do
		local key = resize_keys and resize_keys[name]
		if key and vim.startswith(api.nvim_replace_termcodes(key, true, false, true), send_key) then
			vim.keymap.set("n", "<C-s>", with_chat("send_prompt_buf"), {
				buffer = buf,
				nowait = false,
				desc = "Aero: send prompt",
			})
			break
		end
	end
	map("n", "<CR>", with_chat("send_prompt_buf"), "send prompt")
	-- Enter handles local draft actions; other drafts keep normal newlines.
	vim.keymap.set("i", "<CR>", function()
		if require("aero.acp.path_menu").accept(buf) then return end
		if vim.fn.pumvisible() == 1 then
			local keys = vim.fn.complete_info({ "selected" }).selected == -1 and "<C-n><C-y>" or "<C-y>"
			api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "in", false)
			return
		end
		local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
		if vim.trim(text) == "/report" or vim.trim(text) == "/cancel" or vim.trim(text) == "/export" then
			with_chat("send_prompt_buf")()
		else
			api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "in", false)
		end
	end, { buffer = buf, desc = "Aero: report picker / cancel / newline" })
	map("n", "q", "<cmd>close<cr>", "close prompt (draft is kept)")
	map({ "n", "i" }, "<C-c>", with_chat("cancel"), "cancel turn")
	-- complete the agent's slash commands with <C-x><C-o>
	vim.bo[buf].omnifunc = "v:lua.require'aero.acp'.omnifunc"
	vim.b[buf].aero_chat_key = self.s.key
	require("aero.acp.completion").setup(buf, self.s.worktree)
	require("aero.fullscreen").bind(buf)
	return buf
end

--- Open the prompt window below the transcript and start insert mode.
function Chat:compose()
	local buf = self:get_prompt_buf()
	local tab = api.nvim_get_current_tabpage()
	local existing = vim.tbl_filter(function(w)
		return api.nvim_win_get_tabpage(w) == tab
	end, vim.fn.win_findbuf(buf))
	if #existing > 0 then
		api.nvim_set_current_win(existing[1])
	else
		local tw = vim.fn.bufwinid(self.buf)
		if tw ~= -1 then
			api.nvim_set_current_win(tw)
		end
		local layout = require("aero.layout")
		vim.cmd(("belowright %dsplit"):format(layout.prompt_height(self.s.key)))
		api.nvim_win_set_buf(0, buf)
		if vim.bo[buf].filetype == "" then
			vim.bo[buf].filetype = "markdown"
		end
		chat_win_opts(0, { winfixheight = true })
		layout.track(api.nvim_get_current_win(), "prompt", self.s.key)
	end
	vim.cmd.startinsert({ bang = api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= "" })
end

---------------------------------------------------------------------------
-- Session backend interface (used by Aero.session)
---------------------------------------------------------------------------

local function setup_transcript(chat)
	local buf = chat.buf
	renderer.setup_highlights()
	require("aero.fullscreen").bind(buf)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	set_filetype(buf, "markdown")
	vim.b[buf].aero_session = chat.s.key
	pcall(api.nvim_buf_set_name, buf, ("Aero://%s#%s"):format(chat.s.worktree, chat.s.name))
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "Aero: " .. desc })
	end
	for _, lhs in ipairs({ "i", "a", "o", "I", "A" }) do
		map(lhs, function()
			chat:compose()
		end, "write prompt")
	end
	map("<CR>", function()
		chat:enter_key()
	end, "choose permission option / write prompt")
	map("p", function()
		chat:answer_permission()
	end, "go to the pending permission request")
	map("gP", function()
		require("aero.prompts").open(chat)
	end, "view session prompt history")
	api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = function()
			if chat.permission then
				chat:mark_selected()
			end
		end,
	})
	map("<C-c>", function()
		chat:cancel()
	end, "cancel turn")
	api.nvim_create_autocmd("BufWinEnter", {
		buffer = buf,
		callback = function()
			chat_win_opts(api.nvim_get_current_win(), transcript_win_opts)
		end,
	})
	-- the buffer is already shown when this runs, so BufWinEnter won't fire for those windows
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		chat_win_opts(win, transcript_win_opts)
	end
	require("aero.acp.todos").attach(chat)
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
