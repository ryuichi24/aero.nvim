-- Turn preparation, readiness gates and FIFO dispatch; conversation methods own presentation effects.
local models = require("aero.acp.models")
local modes = require("aero.acp.modes")
local M = {}

function M.ready(chat)
	return chat.state == "ready"
		and not chat.busy
		and not chat.model_pending
		and not chat.mode_pending
		and not chat.task_pending
end

function M.prompt(chat, text)
	local handled, result = require("aero.acp.local_commands").handle(chat, text)

	if handled then
		return result
	end

	if chat.task_pending then
		table.insert(chat.queue, text)
		return chat:changed()
	end

	if vim.trim(text):match("^/new%-ticket%s") or vim.trim(text) == "/new-ticket" then
		if not chat.s.task_binding then
			if not M.ready(chat) then
				table.insert(chat.queue, text)
				return chat:changed()
			end

			return require("aero.tasks.agent").prepare_new_ticket(chat, function()
				chat:prompt(text)
			end)
		end
	end

	local expanded, err = require("aero.tasks.agent").expand_new_ticket(chat.s, text)

	if not expanded then
		vim.notify("Aero: " .. err, vim.log.levels.WARN)
		return
	end

	text = expanded

	-- A queued draft becomes a transcript block only when it is actually submitted.
	if not M.ready(chat) then
		table.insert(chat.queue, text)
		return chat:changed()
	end

	if models.handle(chat, text) or modes.handle(chat, text) then
		return
	end

	local article_text, article_err = require("aero.articles").context(chat.s, text)

	if not article_text then
		vim.notify("Aero: " .. article_err, vim.log.levels.WARN)
		return
	end

	local ok, wire_text = pcall(require("aero.knowledge.agent").context, chat.s, article_text)

	if not ok then
		vim.notify("Aero: cannot prepare knowledge context: " .. tostring(wire_text), vim.log.levels.ERROR)
		return
	end

	local block = { kind = "user", text = text, timestamp = os.time() }
	table.insert(chat.blocks, block)
	chat.turn = (chat.turn or 0) + 1
	local turn = chat.turn
	chat.busy = true
	chat.turn_started, chat.doing = vim.uv.now(), nil
	chat:changed()
	require("aero.spinner").ensure()
	chat.client:request("session/prompt", {
		sessionId = chat.session_id,
		prompt = { { type = "text", text = wire_text } },
	}, function(failure, response)
		chat.busy = false
		require("aero.acp.usage").response(chat, response, turn)

		if failure then
			chat:fail("prompt", failure)
		elseif response and response.stopReason and response.stopReason ~= "end_turn" then
			chat:info("stopped: " .. response.stopReason)
		else
			require("aero.inbox").add(chat, "completed", block, "Turn completed")
		end

		chat:changed()
		chat:flush_queue()
	end)
end

function M.flush(chat)
	local text = table.remove(chat.queue, 1)

	if text then
		chat:prompt(text)
	end
end

return M
