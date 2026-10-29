-- Run: nvim --headless -u NONE -i NONE -l tests/local_commands.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local calls, notices = {}, {}
local selected = { key = "fixture" }
local result = {}
local chat = {
	s = selected,
	buf = vim.api.nvim_get_current_buf(),
	state = "ready",
	busy = true,
	task_pending = true,
	queue = { "retained prompt" },
}

local function record(name, argument)
	table.insert(calls, { name = name, argument = argument })
	return result
end

chat.cancel = function(self)
	return record("cancel", self)
end
package.loaded["aero.session"] = {
	start = function(s, win, resume)
		assert(win == vim.api.nvim_get_current_win() and resume == true)

		return record("resume", s)
	end,
}

for _, command in ipairs({
	{ module = "aero.prompt_snippets", method = "open", name = "prompt" },
	{ module = "aero.exports", method = "export", name = "export" },
	{ module = "aero.reports", method = "pick", name = "report" },
	{ module = "aero.reference", method = "pick", name = "reference" },
}) do
	package.loaded[command.module] = {
		[command.method] = function(argument)
			return record(command.name, argument)
		end,
	}
end

vim.notify = function(message, level)
	table.insert(notices, { message = message, level = level })
end
local commands = require("aero.acp.local_commands")

-- Immediate commands bypass busy/task gates, including the legacy alias.
for _, name in ipairs({ "prompt", "export", "report", "reference", "context", "cancel" }) do
	local handled, value = commands.handle(chat, "  /" .. name .. "\n")
	local expected = name == "context" and "reference" or name

	assert(handled and value == result)
	assert(calls[#calls].name == expected)
	assert(calls[#calls].argument == ((expected == "report" or expected == "reference") and selected or chat))
end

local count = #calls
commands.handle(chat, "/resume")

assert(#calls == count and notices[#notices].level == vim.log.levels.INFO)
assert(not commands.handle(chat, "/report with arguments"), "local commands must match the entire input")
assert(not commands.handle(chat, "/model fixture"), "settings must stay in the scheduled turn path")
assert(not commands.handle(chat, "ordinary prompt"))

chat.state = "exited"

for _, text in ipairs({ "/report", "/reference", "/context", "/cancel", "/model fixture", "ordinary prompt" }) do
	local handled, value = commands.handle(chat, text)

	assert(handled and value == nil and #calls == count)
	assert(notices[#notices].level == vim.log.levels.WARN)
end

for _, name in ipairs({ "resume", "prompt", "export" }) do
	local handled, value = commands.handle(chat, "/" .. name)

	assert(handled and value == result and calls[#calls].name == name)
end

-- A nil command result must still prevent the caller from sending a prompt.
chat.cancel = function() end
chat.state = "ready"
local handled, value = commands.handle(chat, "/cancel")

assert(handled and value == nil)
assert(vim.deep_equal(chat.queue, { "retained prompt" }), "dispatch changed queued input")

print("Local command tests passed (busy/stopped policy, aliases, exact matching, return values).")
vim.cmd("qa!")
