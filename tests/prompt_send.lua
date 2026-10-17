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
function chat:prompt(text) sent = text end
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
print("prompt send: ok")
