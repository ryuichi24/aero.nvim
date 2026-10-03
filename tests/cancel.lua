-- Run from the repository root: nvim --headless -u NONE -l tests/cancel.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	agents = { fixture = { type = "acp", cmd = { "python3", "tests/fixtures/acp.py", "cancel" } } },
})
vim.cmd("runtime plugin/aero.lua")
local sessions, panel = require("aero.session"), require("aero.panel")
local s = sessions.create(vim.fn.getcwd(), "fixture")
assert(panel.show(s))
local function wait(fn)
	assert(vim.wait(5000, fn, 10), "timed out")
end
wait(function()
	return s.chat.state == "ready"
end)
local chat, id = s.chat, s.chat.session_id
assert(vim.tbl_contains(vim.fn.getcompletion("Aero ca", "cmdline"), "cancel"))
local code_win = api.nvim_get_current_win()
for _, method in ipairs({ "command", "slash", "hidden" }) do
	chat:prompt("hold")
	wait(function()
		return chat.permission ~= nil
	end)
	local permission = chat.permission.block
	chat:prompt("queued")
	assert(#chat.queue == 1)
	if method == "slash" then
		chat:compose()
		vim.cmd.stopinsert()
		local complete = require("aero.acp").omnifunc(0, "/ca")
		assert(#complete == 1 and complete[1].word == "/cancel")
		api.nvim_buf_set_lines(chat.prompt_buf, 0, -1, false, { "/cancel" })
		chat:send_prompt_buf()
	else
		api.nvim_set_current_win(code_win)
		if method == "hidden" then
			panel.close()
		end
		vim.cmd("Aero cancel")
		assert(api.nvim_get_current_win() == code_win, "cancel changed focus")
	end
	assert(#chat.queue == 0 and chat.permission == nil)
	assert(permission.answer == "cancelled")
	wait(function()
		return not chat.busy
	end)
	assert(chat.state == "ready" and chat.session_id == id)
	chat:prompt("fresh prompt")
	wait(function()
		return not chat.busy
	end)
	assert(chat.state == "ready" and chat:alive())
end
chat:stop()
wait(function()
	return chat.state == "exited"
end)
vim.fn.delete(dir, "rf")
print("cancel: ok")
vim.cmd("qa!")
