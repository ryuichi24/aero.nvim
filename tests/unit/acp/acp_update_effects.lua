-- Run from the repository root: python3 tests/run.py --unit acp_update_effects
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	agents = { fixture = { type = "acp", cmd = { "unused" } } },
})
local sessions = require("aero.session")
local selected = assert(sessions.create(root, "fixture"))

assert(sessions.start(selected, nil, false, nil, { history_only = true }))

local chat, effects = selected.chat, {}
chat.save_history = function()
	table.insert(effects, "save")
end
chat.render = function()
	table.insert(effects, "render")
end
local published = {}

for _, kind in ipairs({ "model", "mode" }) do
	require("aero.acp." .. kind .. "s").publish = function(owner, change)
		assert(owner == chat)

		if change then
			published[kind] = change
			table.insert(effects, kind)
		end
	end
end

sessions.emit = function()
	table.insert(effects, "session")
end
require("aero.acp.transcript").reveal = function(owner, block, initial_bytes)
	assert(owner == chat and block.text == "Streaming" and initial_bytes == 0)

	table.insert(effects, "reveal")
end
require("aero.acp.todo_notifications").update = function(owner)
	assert(owner == chat and owner.plan.entries[1].content == "Check")

	table.insert(effects, "todos")
end
chat:on_update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Streaming" } })

assert(vim.deep_equal(effects, { "reveal", "save", "render" }))

effects = {}
chat:on_update({ sessionUpdate = "plan", entries = { { content = "Check", status = "pending" } } })

assert(vim.deep_equal(effects, { "todos", "save", "render" }))

effects = {}
chat.modes = { currentModeId = "ask" }
chat:on_update({ sessionUpdate = "current_mode_update", currentModeId = "plan" })

assert(vim.deep_equal(effects, { "mode", "save", "render", "session" }))
assert(published.mode.previous == "ask" and published.mode.id == "plan")

effects = {}
chat.models = { currentModelId = "alpha" }
chat:on_update({
	sessionUpdate = "config_option_update",
	configOptions = {
		{ id = "model", type = "select", currentValue = "beta", options = { { value = "beta", name = "Beta" } } },
		{ id = "mode", type = "select", currentValue = "build", options = { { value = "build", name = "Build" } } },
	},
})

assert(vim.deep_equal(effects, { "model", "mode", "save", "render", "session" }))
assert(published.model.previous == "alpha" and published.model.id == "beta")
assert(published.mode.previous == "plan" and published.mode.id == "build")

effects = {}
chat:on_update({ sessionUpdate = "usage_update", used = 5, size = 100 })

assert(vim.deep_equal(effects, { "save", "render", "session" }))

effects = {}
chat.replaying, chat.replay_from_cache = true, true
chat:on_update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Duplicate" } })
chat.task_reloading = true
chat:on_update({ sessionUpdate = "current_mode_update", currentModeId = "plan" })
chat:on_update({ sessionUpdate = "unknown_update" })

assert(#effects == 0, "suppressed notifications must not produce controller effects")

vim.fn.delete(root, "rf")
print("ACP update controller effect-order tests passed.")
