-- Run: nvim --headless -u NONE -l tests/prompt_send.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local prompt = require("aero.acp.prompt")
local transcript = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(transcript)
vim.cmd("split")
local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
local sent
local chat = { prompt_buf = buf, buf = transcript, s = {}, state = "ready" }
function chat:prompt(text)
	sent = text
end
api.nvim_buf_set_lines(buf, 0, -1, false, { "First snippet", "", "Second snippet", "/send" })
api.nvim_win_set_cursor(0, { 4, 0 })
assert(prompt.command(chat))
assert(sent == "First snippet\n\nSecond snippet", "send command leaked or changed the draft")
assert(api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "")
api.nvim_set_current_buf(buf)
api.nvim_buf_set_lines(buf, 0, -1, false, { "/send" })
sent = nil
assert(prompt.command(chat))
assert(sent == nil, "empty draft was submitted")
local reference = require("aero.reference")
local old_pick, picked = reference.pick, 0
reference.pick = function(s)
	assert(s == chat.s)
	picked = picked + 1
end
for _, command in ipairs({ "/reference", "/context" }) do
	api.nvim_buf_set_lines(buf, 0, -1, false, { "Keep this draft", command, "And this line" })
	api.nvim_win_set_cursor(0, { 2, 0 })
	assert(prompt.command(chat))
	assert(vim.deep_equal(api.nvim_buf_get_lines(buf, 0, -1, false), { "Keep this draft", "And this line" }))
end
assert(picked == 2)
-- Both Enter mappings must dispatch standalone reference commands rather than add a newline.
local mapped_chat = { s = { key = "reference-test", worktree = vim.fn.getcwd(), name = "test" } }
function mapped_chat:save_history() end
function mapped_chat:send_prompt_buf()
	picked = picked + 1
end
local mapped_buf = prompt.buffer(mapped_chat, function()
	return mapped_chat
end)
api.nvim_set_current_buf(mapped_buf)
for _, mode in ipairs({ "n", "i" }) do
	local mapping = vim.fn.maparg("<CR>", mode, false, true)
	for _, command in ipairs({ "/reference", "/context" }) do
		api.nvim_buf_set_lines(mapped_buf, 0, -1, false, { command })
		mapping.callback()
	end
end
assert(picked == 6, "Enter did not dispatch reference commands in both modes")
reference.pick = old_pick
print("prompt send: ok")
