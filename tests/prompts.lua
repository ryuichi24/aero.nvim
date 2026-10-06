-- Run: nvim --headless -u NONE -l tests/prompts.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({
	state_file = dir .. "/state.json", animation = false,
	agents = { fixture = { type = "acp", cmd = { "python3", vim.fn.getcwd() .. "/tests/fixtures/acp.py", "save" } } },
})
vim.cmd.runtime("plugin/aero.lua")
local session = assert(require("aero.session").create(dir, "fixture", "history"))
require("aero.panel").show(session)
assert(vim.wait(5000, function() return session.chat.state == "ready" end, 10))
local chat = session.chat
local prompts = require("aero.prompts")
local message
local notify = vim.notify
vim.notify = function(text) message = text end
vim.cmd("Aero prompts")
assert(message == "Aero: no prompts for history")
vim.notify = notify
local long = "first prompt\n" .. string.rep("full text\n", 40) .. "last line"
chat.blocks = {
	{ kind = "user", text = long }, { kind = "agent", text = "response" },
	{ kind = "user", text = "second prompt" },
}
chat:changed()
assert(#prompts.items(chat) == 2)
vim.cmd("Aero prompts")
local search = api.nvim_get_current_buf()
local function key(name) assert(vim.fn.maparg(name, "n", false, true).callback)() end
local preview, list
for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
	local cfg = api.nvim_win_get_config(win)
	if cfg.focusable == false then
		local buf = api.nvim_win_get_buf(win)
		if vim.bo[buf].filetype == "markdown" then preview = win else list = win end
	end
end
assert(preview and list)
assert(table.concat(api.nvim_buf_get_lines(api.nvim_win_get_buf(preview), 0, -1, false), "\n") == long)
key("<C-d>")
assert(api.nvim_win_get_cursor(preview)[1] > 1, "preview did not scroll")
key("j")
assert(api.nvim_buf_get_lines(api.nvim_win_get_buf(preview), 0, -1, false)[1] == "second prompt")
key("<CR>")
assert(vim.wait(2000, function()
	return api.nvim_get_current_buf() == chat.buf and api.nvim_win_get_cursor(0)[1] == chat.block_lines[chat.blocks[3]]
end, 10), "selection did not jump to prompt")
assert(not api.nvim_buf_is_valid(search))
-- A different viewed conversation supplies only its own blocks.
local other = assert(require("aero.session").create(dir, "fixture", "other"))
require("aero.panel").show(other)
assert(vim.wait(5000, function() return other.chat.state == "ready" end, 10))
other.chat.blocks = { { kind = "user", text = "other session only" } }
other.chat:changed()
vim.cmd("Aero prompts")
key("<CR>")
assert(api.nvim_get_current_buf() == other.chat.buf)
assert(#prompts.items(other.chat) == 1 and #prompts.items(chat) == 2)
require("aero.session").stop(session)
require("aero.session").stop(other)
vim.fn.delete(dir, "rf")
print("prompt history: ok")
