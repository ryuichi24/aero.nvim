-- ACP capability negotiation and new/load selection. The conversation owns readiness and failure effects.
local store = require("aero.store")
local M = {}

local function load_session(chat, base, session_id, previous_id)
	-- Cached errors are not conversation history. A different selected ID must
	-- replay its own transcript, without relabeling the previous conversation.
	chat.replay_from_cache = chat.restored_conversation
		and (not chat.cache_session_id or chat.cache_session_id == session_id)
	local previous_blocks, previous_tools, previous_usage = chat.blocks, chat.tools, chat.usage

	if
		(chat.requested_session_id and chat.requested_session_id ~= previous_id)
		or (chat.cache_session_id and chat.cache_session_id ~= session_id)
	then
		chat.blocks, chat.tools = {}, {}
		chat.usage = nil
		chat.replay_from_cache = false
	end

	chat.replaying = true
	chat.client:request(
		"session/load",
		vim.tbl_extend("force", base, { sessionId = session_id }),
		function(err, response)
			chat.replaying = false

			if not err then
				chat.resumed = true
				chat:info("resumed session", "session")
				return chat:ready(session_id, response)
			end

			-- A transient adapter failure must not replace the original conversation ID.
			chat.blocks, chat.tools = previous_blocks, previous_tools
			chat.usage = previous_usage
			chat:resume_failed(session_id, err)
		end
	)
end

function M.handshake(chat, resume)
	chat.client:request("initialize", {
		protocolVersion = 1,
		clientCapabilities = { fs = { readTextFile = true, writeTextFile = true }, terminal = false },
		clientInfo = { name = "Aero.nvim", title = "Aero.nvim", version = "0.1.0" },
	}, function(err, response)
		if err then
			if chat.requested_session_id then
				return chat:resume_failed(chat.requested_session_id, err)
			end

			return chat:fail("initialize", err)
		end

		chat.agent_info = response.agentInfo
		chat.caps = response.agentCapabilities or {}
		store.load()
		local definition = store.find_session(chat.s.worktree, chat.s.name) or {}
		local previous_id = definition.acp_session_id or chat.saved_session_id
		local session_id = chat.requested_session_id or previous_id
		chat.saved_session_id = chat.cache_session_id or previous_id or session_id
		local base = { cwd = chat.s.worktree, mcpServers = chat.s.mcp_servers or {} }

		if resume and session_id and chat.caps.loadSession then
			return load_session(chat, base, session_id, previous_id)
		end

		if chat.requested_session_id then
			return chat:resume_failed(
				session_id,
				{ code = -32601, message = "agent does not advertise session/load support" }
			)
		end

		if resume and chat.restored_history then
			local reason = not session_id and "no saved ACP session ID"
				or "agent does not advertise session/load support"
			chat:info("saved log restored; could not resume (" .. reason .. "), starting a new session")
		end

		chat:new_session(base)
	end)
end

function M.new_session(chat, params)
	chat.resumed = false
	chat.usage = nil
	chat.usage_seen = nil
	chat.client:request("session/new", params, function(err, response)
		if err then
			return chat:fail("session/new", err)
		end

		chat:ready(response.sessionId, response)
	end)
end

return M
