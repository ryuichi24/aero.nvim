-- Run from the repository root: python3 tests/run.py --unit acp_updates
vim.opt.rtp:prepend(vim.fn.getcwd())
local updates = require("aero.acp.updates")
local chat = { blocks = {}, tools = {}, turn = 1 }
local function apply(kind, fields)
	return updates.apply(chat, vim.tbl_extend("force", fields or {}, { sessionUpdate = kind }))
end

local first = apply("agent_message_chunk", { content = { type = "text", text = "Hello" } })
local second = apply("agent_message_chunk", { content = { type = "text", text = " world" } })

assert(#chat.blocks == 1 and chat.blocks[1].text == "Hello world")
assert(first.reveal.block == chat.blocks[1] and first.reveal.initial_bytes == 0)
assert(second.reveal.block == chat.blocks[1] and second.reveal.initial_bytes == 5)
assert(chat.doing.kind == "writing")

local image = { type = "image", data = "payload", mimeType = "image/png" }
local image_change = apply("agent_message_chunk", { content = image })
image.data = "changed"
apply("agent_message_chunk", { content = { type = "text", text = "After image" } })

assert(image_change.reveal == nil and chat.blocks[2].image.data == "payload")
assert(#chat.blocks == 3 and chat.blocks[3].text == "After image", "text must not merge into an image block")

local tool_change = apply("tool_call", { toolCallId = "run", title = "Tests", kind = "execute", status = "pending" })
local tool = chat.tools.run
apply("tool_call_update", { toolCallId = "run", status = "completed", rawOutput = "passed" })

assert(tool_change.todos == true and chat.tools.run == tool)
assert(tool.title == "Tests" and tool.tool_kind == "execute" and tool.rawOutput == "passed")
assert(chat.doing.kind == "thinking")

local entries = { { content = "Check", status = "pending" } }
apply("plan", { entries = entries })
local plan = chat.plan
local replacement = { { content = "Check", status = "completed" } }
apply("plan", { entries = replacement })

assert(chat.plan == plan and plan.entries == replacement)
assert(chat.todo_notification_snapshot[1].status == "pending", "todo comparison must capture state before mutation")

chat.turn = 2
apply("plan", { entries = entries })

assert(chat.plan ~= plan and chat.plan.turn == 2)

chat.replaying, chat.replay_from_cache = true, true
local before = vim.deepcopy(chat.blocks)

assert(apply("agent_message_chunk", { content = { type = "text", text = "Duplicate" } }) == nil)
assert(apply("tool_call", { toolCallId = "duplicate" }) == nil)
assert(vim.deep_equal(chat.blocks, before) and chat.tools.duplicate == nil)

apply("available_commands_update", { availableCommands = { { name = "inspect" } } })
local usage = apply("usage_update", { used = 5, size = 100 })

assert(chat.commands[1].name == "inspect")
assert(usage.session_changed and chat.usage.context.used == 5)

for _, kind in ipairs({ "current_mode_update", "config_option_update", "current_model_update" }) do
	local change = apply(kind, { currentModeId = "plan" })

	assert(change.settings and change.session_changed)
	assert(chat.modes.currentModeId == "plan", "selector state must be accepted without controller effects")
end

chat.task_reloading = true
local previous_usage = vim.deepcopy(chat.usage)

assert(apply("usage_update", { used = 99, size = 100 }) == nil)
assert(vim.deep_equal(chat.usage, previous_usage), "task reload must suppress metadata updates as well as content")

chat.task_reloading, chat.replay_from_cache = false, false
local replay = apply("agent_thought_chunk", { content = { type = "text", text = "Past thought" } })
apply("tool_call", { toolCallId = "historical", status = "completed" })

assert(replay.reveal == nil and chat.blocks[#chat.blocks - 1].timestamp == nil)
assert(chat.tools.historical.timestamp == nil)
assert(apply("unknown_update") == nil)
assert(package.loaded["aero.acp.transcript"] == nil)
assert(package.loaded["aero.acp.todo_notifications"] == nil, "state updates loaded notification UI")
assert(package.loaded["aero.history"] == nil, "state updates loaded persistence")
assert(package.loaded["aero.events"] == nil, "state updates loaded lifecycle event publication")

print("ACP update mutation tests passed without editor or persistence collaborators.")
