-- Run: nvim --headless -u NONE -l tests/auto_yes.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	agents = { fixture = { type = "acp", cmd = { "python3", "tests/fixtures/acp.py", "cancel" } } },
})
local s = assert(require("aero.session").create(vim.fn.getcwd(), "fixture"))
assert(require("aero.panel").show(s))
assert(vim.wait(5000, function()
	return s.chat.state == "ready"
end, 10))
local chat = s.chat
assert(chat.auto_yes == false, "auto yes should default to disabled")
local options = {
	{ optionId = "always", name = "Always", kind = "allow_always" },
	{ optionId = "once", name = "Yes", kind = "allow_once" },
	{ optionId = "no", name = "No", kind = "reject_once" },
}
local function request(choices)
	local result = {}
	require("aero.acp.requests").handle(chat, "session/request_permission", {
		toolCall = { title = "Run command" },
		options = choices or options,
	}, function(response)
		assert(not result.response, "answered twice")
		result.response = response
	end)
	return result
end
local first, second = request(), request()
assert(#options == 3, "mutated agent options")
assert(not first.response and not second.response)
chat:choose(4)
assert(chat.auto_yes and not chat.permission)
assert(first.response.outcome.optionId == "once")
assert(second.response.outcome.optionId == "once")
local count = #require("aero.inbox").items()
local automatic = request()
assert(automatic.response.outcome.optionId == "once")
assert(not chat.permission and chat.blocks[#chat.blocks].answer:find("auto yes", 1, true))
assert(#require("aero.inbox").items() == count, "auto approval created attention event")
local denied = request({ options[3] })
assert(not denied.response and #chat.permission.block.options == 1)
chat:choose(1)
assert(denied.response.outcome.optionId == "no")
chat:toggle_auto_yes()
local manual = request()
assert(not manual.response and chat.permission)
chat:toggle_auto_yes()
assert(manual.response.outcome.optionId == "once" and chat.auto_yes)
chat:toggle_auto_yes()
local ordinary = request()
chat:choose(1)
assert(ordinary.response.outcome.optionId == "always" and not chat.auto_yes)
chat:stop()
require("aero.config").options.acp.auto_yes = true
local configured = assert(require("aero.session").create(vim.fn.getcwd(), "fixture"))
assert(require("aero.panel").show(configured))
assert(vim.wait(5000, function()
	return configured.chat.state == "ready"
end, 10))
chat = configured.chat
assert(chat.auto_yes, "new conversation ignored setup default")
assert(request().response.outcome.optionId == "once")
chat:toggle_auto_yes()
local overridden = request()
assert(not overridden.response, "conversation toggle did not override setup default")
chat:choose(2)
chat:stop()
vim.fn.delete(dir, "rf")
print("auto yes: ok")
vim.cmd("qa!")
