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
local command_timestamp = chat.tools.command.timestamp
assert(type(command_timestamp) == "number", "tool call has no event timestamp")
chat:on_update({ sessionUpdate = "tool_call_update", toolCallId = "command", status = "completed" })
assert(chat.tools.command.timestamp == command_timestamp, "tool update changed the original timestamp")
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
wait(function()
	local rendered = text()
	return rendered:find("command stderr", 1, true)
		and rendered:find("The changes look good.", 1, true)
		and rendered:find("```lua\nreturn true\n```", 1, true)
end)
local transcript = text()
assert(transcript:find("### ✓ Command · completed · " .. os.date("%Y-%m-%d %H:%M:%S", command_timestamp), 1, true), "tool timestamp missing from transcript")
wait(function() return vim.wo[require("aero.panel").win()].winbar:find("Todos 1/2 completed", 1, true) end)
local bar = vim.wo[require("aero.panel").win()].winbar
assert(bar:find("Run the tests", 1, true) and bar:find(s.name, 1, true), "todo summary replaced session details")
assert(not bar:find("gT: list", 1, true), "legacy todo popup hint remains")
assert(vim.tbl_isempty(vim.fn.maparg("gT", "n", false, true)), "legacy todo popup mapping remains")
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

-- Following the tail stays bottom-aligned while focused, including edits above it.
local log_win = api.nvim_get_current_win()
vim.wo[log_win].scrolloff = 5
api.nvim_win_set_cursor(log_win, { api.nvim_buf_line_count(s.buf), 0 })
vim.cmd("normal! zb")
vim.cmd("redraw")
local tail_row = vim.fn.winline()
-- The cursor can remain on the tail even when the viewport has shifted.
vim.cmd("normal! zt")
for i = 1, 4 do
	chat.blocks[#chat.blocks].text = chat.blocks[#chat.blocks].text .. "\nstreamed detail " .. i
	chat:render()
	wait(function()
		return text():find("streamed detail " .. i, 1, true)
	end)
	vim.cmd("redraw")
	assert(vim.fn.winline() == tail_row, "focused transcript tail moved away from the bottom")
end

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
assert(last == first + 2, "permission range must include the auto yes option")
assert(api.nvim_win_get_cursor(0)[1] == first, "permission request did not select the first option")
assert(api.nvim_buf_get_lines(s.buf, first, first + 1, false)[1] == "  2. Reject")
assert(api.nvim_buf_get_lines(s.buf, last - 1, last, false)[1] == "  3. Auto yes for this conversation")
api.nvim_win_set_cursor(0, { first + 1, 0 })
chat:enter_key()
assert(outcome and outcome.optionId == "reject", "rendered permission options selected the wrong action")
wait(function() return text():find("→ Reject", 1, true) end)

-- Concurrent requests retain their callbacks, and each card selects its own option.
local answers, requests = {}, {}
local function request_permission(id)
	chat:on_request("session/request_permission", {
		toolCall = { toolCallId = id, title = id },
		options = {
			{ optionId = id .. "-allow", name = "Allow", kind = "allow_once" },
			{ optionId = id .. "-reject", name = "Reject", kind = "reject_once" },
		},
	}, function(response)
		assert(not answers[id], "permission callback invoked twice")
		answers[id] = response.outcome
	end)
	requests[id] = chat.blocks[#chat.blocks]
end
request_permission("first")
request_permission("second")
chat:render()
wait(function() return chat:option_range(requests.second) ~= nil end)
local second_first, second_last = chat:option_range(requests.second)
assert(second_first and second_last == second_first + 2)
assert(chat.permission.block == requests.first, "concurrent request replaced the active permission")
local pending_inbox = {}
for _, entry in ipairs(require("aero.inbox").items()) do
	pending_inbox[entry.block] = true
end
assert(pending_inbox[requests.first] and pending_inbox[requests.second], "inbox dropped a concurrent permission")
api.nvim_win_set_cursor(0, { second_first + 1, 0 })
chat:enter_key()
assert(answers.second.optionId == "second-reject" and not answers.first, "option answered the wrong request")
assert(chat.permission.block == requests.first)
chat:render()
wait(function() return chat:option_range(requests.second) == nil end)
api.nvim_win_set_cursor(0, { chat:option_range(requests.first), 0 })
vim.fn.maparg("1", "n", false, true).callback()
assert(answers.first.optionId == "first-allow" and not chat.permission and #chat.permissions == 0)
request_permission("cancel-first")
request_permission("cancel-second")
chat:cancel()
assert(answers["cancel-first"].outcome == "cancelled" and answers["cancel-second"].outcome == "cancelled")
assert(not chat.permission and #chat.permissions == 0)
wait(function() return text():find("→ cancelled", 1, true) end)

-- Render caches must not be serialized, but command data and metadata must survive.
history.flush(s)
local saved = history.load(s)
local saved_command, saved_error
for _, block in ipairs(saved.blocks) do
	assert(block.cache == nil and block.cache_src == nil and block.shown == nil, "render caches leaked into history")
	if block.id == "command" then saved_command = block end
	if block.meta_kind == "error" then saved_error = block end
end
assert(saved_command.rawInput.command == "printf 'hello'\nprintf 'world'" and saved_command.rawOutput == "hello\nworld\nextra output")
assert(saved_command.timestamp == command_timestamp, "event timestamp was not persisted")
assert(saved_error, "typed metadata was not saved")

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

-- Image chunks remain separate from following text and survive saved history.
config.options.acp.image_previews = true
local image = { type = "image", mimeType = "image/png", data = vim.base64.encode("\137PNG\0test") }
chat:on_update({ sessionUpdate = "agent_message_chunk", content = image })
chat:on_update({ sessionUpdate = "agent_message_chunk", content = { type = "text", text = "After the screenshot." } })
wait(function() return text():find("![image](/", 1, true) and text():find("After the screenshot.", 1, true) end)
assert(chat.blocks[#chat.blocks - 1].image.data == image.data)
assert(chat.blocks[#chat.blocks].text == "After the screenshot.")
history.flush(s)
assert(history.load(s).blocks[#chat.blocks - 1].image.data == image.data, "image payload was not persisted")
local cached_image = require("aero.acp.images").markdown(image):match("%((.*)%)")
vim.fn.delete(cached_image)
sessions.delete(s)
api.nvim_create_autocmd("VimLeavePre", { once = true, callback = function() vim.fn.delete(dir, "rf") end })
print("Transcript tests passed (typed cards, metadata, commands, diffs, truncation, decoration, permissions, history).")
