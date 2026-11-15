-- Run from the repository root: python3 tests/run.py --unit acp_permissions
vim.opt.rtp:prepend(vim.fn.getcwd())
local permissions = require("aero.acp.permissions")
local chat = { blocks = {}, tools = { known = { title = "Known tool" } } }
local effects_log = {}
local effects = {
	pending = function(owner)
		assert(owner == chat)

		table.insert(effects_log, "pending")
	end,
	answered = function(owner)
		assert(owner == chat)

		table.insert(effects_log, "answered")
	end,
}
local choices = {
	{ optionId = "always", name = "Always", kind = "allow_always" },
	{ optionId = "once", name = "Once", kind = "allow_once" },
	{ optionId = "aero:auto-yes", name = "No", kind = "reject_once" },
	{ optionId = "aero:auto-yes:", name = "Never", kind = "reject_always" },
}
local function request(options)
	local result = {}
	local block, queued = permissions.request(chat, {
		toolCall = { toolCallId = "known" },
		options = options or choices,
	}, function(response)
		assert(not result.response, "permission answered more than once")

		result.response = response.outcome
		table.insert(effects_log, "respond")
	end)
	result.block, result.queued = block, queued
	return result
end

local first, second = request(), request()

assert(first.queued and second.queued and #chat.permissions == 2)
assert(first.block.title == "Known tool")
assert(first.block.options[5].optionId == "aero:auto-yes::", "synthetic option collided with adapter IDs")
assert(first.block.options[5].auto_yes == "once", "auto-yes must prefer allow-once over allow-always")
assert(#choices == 4, "request creation mutated adapter options")

permissions.choose(chat, 99, second.block, effects)
permissions.choose(chat, 1, {}, effects)

assert(#effects_log == 0 and #chat.permissions == 2, "invalid/stale selection must not respond or change UI")

permissions.choose(chat, 2, second.block, effects)

assert(second.response.optionId == "once" and not first.response)
assert(chat.permission.block == first.block and #chat.permissions == 1)
assert(vim.deep_equal(effects_log, { "pending", "respond", "answered" }))

effects_log = {}
local denied = request({ choices[3] })
local third = request()
permissions.choose(chat, 5, first.block, effects)

assert(chat.auto_yes and first.response.optionId == "once" and third.response.optionId == "once")
assert(
	not denied.response and chat.permission.block == denied.block,
	"auto-yes approved a request without an allow option"
)

local automatic = request()

assert(not automatic.queued and automatic.response.optionId == "once")
assert(automatic.block.answer == "Once (auto yes)")
assert(#chat.permissions == 1, "automatic response changed the pending rejection-only request")

assert(not permissions.toggle_auto_yes(chat, effects))

local pending = request()
local prepared = false
permissions.cancel(chat, function(owner)
	assert(
		owner.permission == nil and #owner.permissions == 0,
		"cancel must clear the queue before UI and protocol effects"
	)

	prepared = true
end)

assert(prepared and denied.response.outcome == "cancelled" and pending.response.outcome == "cancelled")
assert(denied.block.answer == "cancelled" and pending.block.answer == "cancelled")

permissions.cancel(chat, function()
	error("empty cancellation must not trigger UI effects")
end)
local interrupted = request()
permissions.clear(chat)

assert(
	not chat.permission and #chat.permissions == 0 and not interrupted.response,
	"adapter exit must not respond on its closed connection"
)
assert(package.loaded["aero.acp.editor_state"] == nil)
assert(package.loaded["aero.inbox"] == nil)
assert(package.loaded["aero.acp.transcript"] == nil)

print("Permission policy/queue tests passed without editor collaborators.")
