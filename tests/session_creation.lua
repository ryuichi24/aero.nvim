-- Run from the repository root: nvim --headless -u NONE -l tests/session_creation.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
dir = vim.fn.resolve(dir)
require("aero.git").list = function()
	return { { path = dir, branch = "main" } }
end
require("aero").setup({ state_file = dir .. "/state.json", animation = false, start_insert = false })
require("aero.store").add_workspace(dir)
local sessions = require("aero.session")
local shown
require("aero.panel").focus = function(s)
	shown = s
end
local dashboard = require("aero.dashboard")
dashboard.open()
local function press(key)
	api.nvim_win_set_cursor(0, { 4, 0 })
	vim.fn.maparg(key, "n", false, true).callback()
end
local input, inputs = "opencode-acp", 0
vim.ui.input = function(_, callback)
	inputs = inputs + 1
	callback(input)
end
press("O")
local first = shown
input = "opencode-acp-2"
press("O")
assert(shown ~= first and #sessions.list(dir) == 2, "uppercase shortcut reused a session")
assert(shown.fresh and shown.name == "opencode-acp-2")
input = "opencode"
press("o")
local terminal = shown
input = "opencode-2"
press("o")
assert(shown ~= terminal and shown.name == "opencode-2" and shown.fresh,
	"lowercase shortcut reused a session")
vim.ui.select = function(_, _, callback)
	callback("opencode-acp")
end
assert(inputs == 4, "agent shortcuts did not prompt for names")
input = "  investigate bug  "
press("a")
assert(shown.name == "investigate bug" and shown.fresh)
local count = #sessions.list(dir)
local named = shown
press("a")
assert(#sessions.list(dir) == count and shown == named, "duplicate name created a session")
for _, value in ipairs({ "", "   ", "bad\nname" }) do
	input = value
	press("a")
	assert(#sessions.list(dir) == count)
end
input = nil
press("a")
assert(#sessions.list(dir) == count, "cancelled prompt created a session")
for _, key in ipairs({ "c", "x", "o", "C", "X", "O" }) do
	local previous_inputs = inputs
	press(key)
	assert(inputs == previous_inputs + 1 and #sessions.list(dir) == count,
		"cancelled shortcut prompt created a session or did not prompt")
end
require("aero.config").options.prompt_session_name = false
local previous_inputs = inputs
press("a")
assert(inputs == previous_inputs and #sessions.list(dir) == count + 1)
assert(shown.name == "opencode-acp-3" and shown.fresh)
press("o")
assert(inputs == previous_inputs and shown.name == "opencode-3" and shown.fresh)
vim.fn.delete(dir, "rf")
print("Session creation tests passed.")
