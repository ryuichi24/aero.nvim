-- Run from the repository root: nvim --headless -u NONE -l tests/transcript.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({
	state_file = dir .. "/state.json", animation = false, start_insert = false,
	acp = { max_tool_lines = 2 },
	agents = { fixture = { type = "acp", cmd = { "python3", "tests/fixtures/acp.py", "save" } } },
})
local sessions, history = require("aero.session"), require("aero.history")
local s = sessions.create(vim.fn.getcwd(), "fixture")
assert(require("aero.panel").show(s))
api.nvim_set_current_win(require("aero.panel").win())
local function wait(fn)
	assert(vim.wait(5000, fn, 10), "timed out")
end
wait(function() return s.chat.state == "ready" end)
local chat = s.chat
local function text()
	return table.concat(api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n")
end
chat:info("Model: OpenAI/GPT-6 Luna (openai/gpt-6-luna)")
chat:info("Model: OpenAI/GPT-6.1 Sol (openai/gpt-6.1-sol)")
chat:info("resumed session")
chat:on_update({ sessionUpdate = "user_message_chunk", content = { type = "text", text = "Inspect the changes." } })
chat:on_update({ sessionUpdate = "agent_thought_chunk", content = { type = "text", text = "Compare the two implementations.\nCheck the tests." } })
chat:on_update({
	sessionUpdate = "tool_call", toolCallId = "read", kind = "read", title = "Read\nsource files", status = "completed",
	locations = { { path = "src/main.lua", line = 41 } },
	content = { { type = "content", content = { type = "text", text = "first output\nsecond output\nthird output\nfourth output" } } },
})
chat:on_update({
	sessionUpdate = "tool_call", toolCallId = "command", kind = "execute", title = "Run tests", status = "pending",
	rawInput = { command = "printf 'hello'\nprintf 'world'", cwd = "/tmp/project" },
})
chat:on_update({ sessionUpdate = "tool_call_update", toolCallId = "command", status = "completed", rawOutput = "hello\nworld\nextra output" })
chat:on_update({
	sessionUpdate = "tool_call", toolCallId = "edit", kind = "edit", title = "Update a file", status = "failed",
	content = { { type = "diff", path = "src/main.lua", oldText = "old\n", newText = "new\n" } },
})
chat:on_update({ sessionUpdate = "plan", entries = {
	{ content = "Read the source", status = "completed" }, { content = "Run the tests", status = "in_progress" },
} })
chat:on_update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "The changes look good.\n\n```lua\nreturn true\n```" } })
chat:fail("test command", { message = "Exit status 1\ncommand stderr", code = -32000 })
chat:advance(true)
chat:changed()
wait(function() return text():find("command stderr", 1, true) end)
local transcript = text()
local _, metadata_cards = transcript:gsub("### Session", "")
assert(metadata_cards == 1, "consecutive metadata did not form one compact card")
assert(transcript:find("Model: OpenAI/GPT-6 Luna (openai/gpt-6-luna)\nModel: OpenAI/GPT-6.1 Sol", 1, true))
assert(not transcript:find("_Model:", 1, true), "model metadata still uses isolated italic paragraphs")
for _, value in ipairs({
	"## You", "### Thinking", "### ✓ Read · completed", "Read ⏎ source files", "src/main.lua:42",
	"### ✓ Command · completed", "```sh\nprintf 'hello'\nprintf 'world'\n```", "cwd: /tmp/project",
	"```text\nhello\nworld\n… 1 more lines\n```", "… 2 more lines", "### ✗ Edit · failed",
	"```diff\n--- src/main.lua\n+++ src/main.lua", "-old", "+new", "### Plan", "- [x] Read the source",
	"- [~] Run the tests", "The changes look good.", "```lua\nreturn true\n```", "### Error", "test command failed:",
}) do
	assert(transcript:find(value, 1, true), "missing rendered content: " .. value .. "\n" .. transcript)
end

local ns = api.nvim_create_namespace("Aero.acp.render")
local function marks()
	return api.nvim_buf_get_extmarks(s.buf, ns, 0, -1, { details = true })
end
assert(#marks() > 0, "transcript has no visual decoration")
local seen, first_mark = {}, marks()[1][1]
for _, mark in ipairs(marks()) do
	local details = mark[4]
	if details.hl_group then seen[details.hl_group] = true end
	if details.virt_text then
		assert(details.virt_text_pos == "inline", "card border obscures selectable text")
	end
end
assert(seen.AeroChatThinking and seen.AeroChatCommand and seen.AeroChatMeta and seen.AeroChatError)
assert(seen.AeroChatSuccess, "tool statuses do not have separate highlighting")
assert(not transcript:find("│", 1, true), "visual borders leaked into the actual log text")

-- Updating only the tail should preserve decorations on earlier cards.
chat.blocks[#chat.blocks].text = chat.blocks[#chat.blocks].text .. "\nextra detail"
chat:render()
wait(function() return text():find("extra detail", 1, true) end)
assert(marks()[1][1] == first_mark, "streaming rebuilt decorations for the unchanged transcript prefix")

-- Permission options still map to the right lines and remain actionable.
local outcome
chat:on_request("session/request_permission", {
	toolCall = { toolCallId = "permission", title = "Execute a command" },
	options = {
		{ optionId = "allow", name = "Allow once", kind = "allow_once" },
		{ optionId = "reject", name = "Reject", kind = "reject_once" },
	},
}, function(response) outcome = response.outcome end)
wait(function() return text():find("### Permission requested", 1, true) and not chat.pending_focus end)
local first, last = chat:option_range()
assert(last == first + 1 and api.nvim_win_get_cursor(0)[1] == first)
assert(api.nvim_buf_get_lines(s.buf, last - 1, last, false)[1] == "  2. Reject")
api.nvim_win_set_cursor(0, { last, 0 })
chat:enter_key()
assert(outcome and outcome.optionId == "reject", "rendered permission options selected the wrong action")
wait(function() return text():find("→ Reject", 1, true) end)

-- Render caches must not be serialized, but command data and metadata must survive.
history.flush(s)
local saved = history.load(s)
local saved_command
for _, block in ipairs(saved.blocks) do
	assert(block.cache == nil and block.cache_src == nil and block.shown == nil, "render caches leaked into history")
	if block.id == "command" then saved_command = block end
end
assert(saved_command.rawInput.command == "printf 'hello'\nprintf 'world'" and saved_command.rawOutput == "hello\nworld\nextra output")
assert(saved.blocks[#saved.blocks - 1].meta_kind == "error", "typed metadata was not saved")

-- Structured execution results have readable stdout/stderr and exit metadata.
chat:on_update({
	sessionUpdate = "tool_call_update", toolCallId = "command", status = "failed",
	rawInput = { command = { "git", "-C", "project folder", "status" } },
	rawOutput = { stdout = "command output\n", stderr = "command error\n", exitCode = 2 },
})
wait(function() return text():find("Exit: 2", 1, true) end)
assert(text():find("git -C 'project folder' status", 1, true), "command arguments were not represented accurately")
assert(text():find("Output\n```text\ncommand output\n```", 1, true))
assert(text():find("stderr\n```text\ncommand error\n```", 1, true))

-- Decoration preferences apply even when the transcript's text hasn't changed.
local config = require("aero.config")
config.options.acp.decorations = false
chat:render()
wait(function() return #marks() == 0 end)
config.options.acp.decorations = true
chat:render()
wait(function() return #marks() > 0 end)
sessions.delete(s)
api.nvim_create_autocmd("VimLeavePre", { once = true, callback = function() vim.fn.delete(dir, "rf") end })
print("Transcript tests passed (typed cards, metadata, commands, diffs, truncation, decoration, permissions, history).")
