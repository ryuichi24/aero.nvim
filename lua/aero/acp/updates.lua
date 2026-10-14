-- Apply agent notifications to conversation blocks/settings, preserving replay rules.
local M = {}

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
	if kind == "user_message_chunk" then
		chat:append_content("user", update.content)
	elseif kind == "agent_message_chunk" then
		chat:append_content("agent", update.content)
		chat.doing = { kind = "writing" }
	elseif kind == "agent_thought_chunk" then
		chat:append_content("thought", update.content)
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
		chat:accept_settings(update)
		return chat:changed()
	elseif kind == "usage_update" then
		require("aero.acp.usage").update(chat, update)
		return chat:changed()
	else
		return
	end
	if todo_update then
		require("aero.acp.todo_notifications").update(chat)
	end
	chat:save_history()
	chat:render()
end

return M
