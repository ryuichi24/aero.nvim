-- Immediate composer commands run before task preparation and turn scheduling.
-- Model/mode commands remain in the conversation's ready-turn path.
local M = {}
local commands = {
	["/resume"] = {
		while_stopped = true,
		run = function(chat)
			if chat.state ~= "exited" then
				return vim.notify("Aero: session is already running", vim.log.levels.INFO)
			end

			local win = vim.fn.win_findbuf(chat.buf)[1]
			return require("aero.session").start(chat.s, win, true)
		end,
	},
	["/prompt"] = {
		while_stopped = true,
		run = function(chat)
			return require("aero.prompt_snippets").open(chat)
		end,
	},
	["/export"] = {
		while_stopped = true,
		run = function(chat)
			return require("aero.exports").export(chat)
		end,
	},
	["/report"] = {
		run = function(chat)
			return require("aero.reports").pick(chat.s)
		end,
	},
	["/reference"] = {
		run = function(chat)
			return require("aero.reference").pick(chat.s)
		end,
	},
	["/cancel"] = {
		run = function(chat)
			return chat:cancel()
		end,
	},
}

--- Return handled separately from the command result: most commands return nil.
--- Stopped conversations also consume unsupported commands and ordinary prompts.
function M.handle(chat, text)
	local name = vim.trim(text)

	if name == "/context" then
		name = "/reference"
	end -- legacy prompt alias

	local command = commands[name]

	if chat.state == "exited" and not (command and command.while_stopped) then
		vim.notify("Aero: session is stopped; send /resume in the composer to resume it", vim.log.levels.WARN)
		return true
	end

	if command then
		return true, command.run(chat)
	end

	return false
end

return M
