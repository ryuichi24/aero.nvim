-- Apply notification state changes and describe controller work, preserving replay rules.
local content = require("aero.acp.content")
local models = require("aero.acp.models")
local modes = require("aero.acp.modes")
local M = {}

---@class aero.acp.UpdateChange
---@field reveal? {block: table, initial_bytes: integer}
---@field todos? boolean
---@field settings? {model?: aero.acp.SelectorChange, mode?: aero.acp.SelectorChange}
---@field session_changed? boolean publish session metadata changes as well as saving/rendering

---@return aero.acp.UpdateChange? change nil means no controller effects
function M.apply(chat, update)
	if chat.task_reloading then
		return
	end

	local kind = update.sessionUpdate
	local todo_update = kind == "plan" or kind == "tool_call" or kind == "tool_call_update"

	if todo_update then
		chat.todo_notification_snapshot = vim.deepcopy(require("aero.acp.todos").latest(chat))
	end

	if
		chat.replaying
		and chat.replay_from_cache
		and kind ~= "available_commands_update"
		and kind ~= "current_mode_update"
		and kind ~= "config_option_update"
		and kind ~= "current_model_update"
		and kind ~= "usage_update"
	then
		return
	end

	local change = { todos = todo_update }

	if kind == "user_message_chunk" then
		change.reveal = content.append_content(chat, "user", update.content)
	elseif kind == "agent_message_chunk" then
		change.reveal = content.append_content(chat, "agent", update.content)
		chat.doing = { kind = "writing" }
	elseif kind == "agent_thought_chunk" then
		change.reveal = content.append_content(chat, "thought", update.content)
		chat.doing = { kind = "thinking" }
	elseif kind == "tool_call" or kind == "tool_call_update" then
		if update.status == "completed" or update.status == "failed" then
			if chat.doing and chat.doing.id == update.toolCallId then
				chat.doing = { kind = "thinking" }
			end
		else
			chat.doing = { kind = "tool", id = update.toolCallId }
		end

		local block = chat.tools[update.toolCallId]

		if not block then
			block = { kind = "tool", id = update.toolCallId, timestamp = not chat.replaying and os.time() or nil }
			chat.tools[update.toolCallId] = block
			table.insert(chat.blocks, block)
		end

		for _, field in ipairs({ "title", "status", "content", "locations", "rawInput", "rawOutput" }) do
			if update[field] ~= nil then
				block[field] = update[field]
			end
		end

		block.tool_kind = update.kind or block.tool_kind
	elseif kind == "plan" then
		if chat.plan and chat.plan.turn == chat.turn then
			chat.plan.entries = update.entries
		else
			chat.plan = {
				kind = "plan",
				entries = update.entries,
				turn = chat.turn,
				timestamp = not chat.replaying and os.time() or nil,
			}
			table.insert(chat.blocks, chat.plan)
		end
	elseif kind == "available_commands_update" then
		chat.commands = update.availableCommands
	elseif kind == "current_mode_update" or kind == "config_option_update" or kind == "current_model_update" then
		-- Both selectors share config_options; capture mode before model mutation replaces it.
		local previous_mode = modes.current(chat)
		local model = models.apply(chat, update)
		local mode = modes.apply(chat, update, previous_mode)
		return { settings = { model = model, mode = mode }, session_changed = true }
	elseif kind == "usage_update" then
		require("aero.acp.usage").update(chat, update)
		return { session_changed = true }
	else
		return
	end

	return change
end

return M
