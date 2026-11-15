-- Run from the repository root: python3 tests/run.py --unit acp_selectors
vim.opt.rtp:prepend(vim.fn.getcwd())
local models = require("aero.acp.models")
local chat = {
	state = "ready",
	session_id = "conversation",
	models = {
		currentModelId = "alpha",
		availableModels = { { modelId = "alpha", name = "Alpha" }, { modelId = "beta", name = "Beta" } },
	},
}

-- Mutation also supports state-only consumers that have no runtime session owner.
local change = models.apply(chat, { currentModelId = "beta" })

assert(models.current(chat) == "beta")
assert(vim.deep_equal(change, { previous = "alpha", id = "beta", name = "Beta" }))
assert(package.loaded["aero.events"] == nil, "selector mutation loaded lifecycle effects")

local events = require("aero.events")
local emitted = {}
chat.s = { key = "fixture", name = "Session", worktree = "/project", agent = "fixture", chat = chat }
events.on("session_model_changed", function(event)
	table.insert(emitted, event)
end)
models.publish(chat, change)

assert(#emitted == 1)
assert(emitted[1].previous_model_id == "alpha" and emitted[1].model_id == "beta")
assert(emitted[1].model_name == "Beta" and emitted[1].session_id == "conversation")
assert(emitted[1].key == "fixture")

models.publish(chat, models.apply(chat, { currentModelId = "beta" }))

assert(#emitted == 1, "unchanged selection emitted a lifecycle event")
assert(models.apply(chat, nil) == nil)

change = models.apply(chat, { currentModelId = "alpha" })
chat.state = "exited"
models.publish(chat, change)
chat.state, chat.s.chat = "ready", {}
models.publish(chat, change)

assert(#emitted == 1, "exited or replaced conversations must not publish captured transitions")

chat.s.chat = chat
models.accept(chat, { currentModelId = "beta" })

assert(#emitted == 2 and emitted[2].previous_model_id == "alpha", "accept lost its mutation/publication compatibility")

local initial = { models = {} }

assert(models.apply(initial, { currentModelId = "alpha" }) == nil, "initial selection must not invent a previous ID")
assert(models.current(initial) == "alpha")

-- The same factory supplies mode transitions and their legacy payload names.
local modes = require("aero.acp.modes")
chat.modes = { currentModeId = "ask", availableModes = { { id = "plan", name = "Plan" } } }
local mode_event
events.on("session_mode_changed", function(event)
	mode_event = event
end)
modes.accept(chat, { currentModeId = "plan" })

assert(mode_event.previous_mode_id == "ask" and mode_event.mode_id == "plan" and mode_event.mode_name == "Plan")

-- Explicit previous values survive config-option replacement shared by model and mode selectors.
local previous_mode = modes.current(chat)
local response = {
	configOptions = {
		{ id = "model", type = "select", currentValue = "alpha", options = {} },
		{ id = "mode", type = "select", currentValue = "build", options = {} },
	},
}
models.apply(chat, response)
local mode_change = modes.apply(chat, response, previous_mode)

assert(mode_change.previous == "plan" and mode_change.id == "build")

print("Selector mutation/publication tests passed.")
