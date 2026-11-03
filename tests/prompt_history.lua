-- Run: nvim --headless -u NONE -l tests/prompt_history.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local prompt = require("aero.acp.prompt")
local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
local chat = {
	prompt_buf = buf,
	blocks = {
		{ kind = "user", text = "first\ncontinued" },
		{ kind = "agent", text = "response" },
		{ kind = "user", text = "second" },
	},
}
api.nvim_buf_set_lines(buf, 0, -1, false, { "my draft" })
api.nvim_win_set_cursor(0, { 1, 3 })

assert(prompt.history(chat, -1))
assert(api.nvim_get_current_line() == "second")
assert(vim.wo.winbar == "%=Prompt · History 2/2 ")
assert(prompt.history(chat, -1))
assert(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") == "first\ncontinued")
assert(prompt.history(chat, 1))
assert(api.nvim_get_current_line() == "second")
assert(prompt.history(chat, 1))
assert(api.nvim_get_current_line() == "my draft")
assert(vim.wo.winbar == "%=Prompt · History —/2 (draft) ")
assert(api.nvim_win_get_cursor(0)[2] == 3)
assert(not prompt.history(chat, 1))
assert(prompt.history(chat, -1))

api.nvim_buf_set_lines(buf, 0, -1, false, { "edited recall" })

assert(prompt.history(chat, -1))
assert(prompt.history(chat, 1))
assert(api.nvim_get_current_line() == "edited recall")

chat.blocks = {}

api.nvim_buf_set_lines(buf, 0, -1, false, { "empty history draft" })

assert(not prompt.history(chat, -1))
assert(api.nvim_get_current_line() == "empty history draft")

print("Prompt history navigation tests passed")
