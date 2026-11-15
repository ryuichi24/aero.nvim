-- Editor completion for local commands and agent-advertised slash commands.
local M = {}
local commands = {
	{ "/export", "Save this conversation as Markdown" },
	{ "/model", "Choose the session's AI model" },
	{ "/mode", "Choose the session mode" },
	{ "/report", "Attach a worktree report to the draft" },
	{ "/reading", "Draft a named source-code walkthrough request" },
	{ "/reading-update", "Select an existing reading list to update" },
	{ "/prompt", "Insert a custom prompt snippet into the draft" },
	{ "/history", "Reuse a previous session prompt in the draft" },
	{ "/send", "Submit the current draft" },
	{ "/reference", "Attach a worktree reference file or folder" },
	{ "/cancel", "Cancel the current turn and discard queued prompts" },
	{ "/resume", "Resume the stopped session" },
	{ "/new-ticket", "Create an Aero ticket with initial content through MCP" },
}

function M.complete(chat, findstart, base)
	local line = vim.api.nvim_get_current_line():sub(1, vim.api.nvim_win_get_cursor(0)[2])
	local prefix = line:match("^(%s*/model%s+)") or line:match("^(%s*/mode%s+)")

	if findstart == 1 then
		if prefix then
			return #prefix
		end

		local start = line:find("/[%w%-_]*$")
		return start and start - 1 or -3
	end

	local out, reserved = {}, {}

	if prefix then
		local selector = require("aero.acp." .. (prefix:match("/model%s") and "models" or "modes"))

		for _, choice in ipairs(selector.options(chat).choices) do
			if choice.id:sub(1, #base) == base then
				table.insert(
					out,
					{ word = choice.id, abbr = choice.name, menu = choice.group or choice.description or "" }
				)
			end
		end

		return out
	end

	for _, command in ipairs(commands) do
		reserved[command[1]] = true

		if command[1]:sub(1, #base) == base then
			table.insert(out, { word = command[1], menu = command[2] })
		end
	end

	if chat and require("aero.knowledge.agent").scope(chat.s) then
		for word, description in pairs({
			["/source"] = "Choose a knowledge source for this session",
			["/tag"] = "Choose session sources by tag",
		}) do
			reserved[word] = true

			if word:sub(1, #base) == base then
				table.insert(out, { word = word, menu = description })
			end
		end
	end

	for _, command in ipairs(chat and chat.commands or {}) do
		local word = "/" .. command.name

		if not reserved[word] and word:find(base, 1, true) == 1 then
			table.insert(out, { word = word, menu = command.description })
		end
	end

	return out
end

return M
