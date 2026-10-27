vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero.config").setup({
	state_file = dir .. "/state.json",
	animation = false,
	agents = { fixture = { type = "acp", cmd = { "python3", "tests/fixtures/acp.py", "replay" } } },
})
local sessions = require("aero.session")
local history = require("aero.history")
local s = sessions.create(vim.fn.getcwd(), "fixture")
s.fresh = false
history.save(s, function()
	return {
		type = "acp",
		session_id = "fixture-session",
		blocks = { { kind = "user", text = "saved question" } },
	}
end)
history.flush(s)

assert(sessions.show(s, 0))
assert(s.chat.state == "exited" and not s.chat.client, "opening history spawned an agent")
assert(not sessions.is_running(s))
assert(s.chat.blocks[1].text == "saved question", "saved transcript was not restored")

local chat = s.chat

assert(sessions.show(s, 0))
assert(s.chat == chat, "reopening history replaced the chat")

chat:compose()
vim.api.nvim_buf_set_lines(chat.prompt_buf, 0, -1, false, { "/resume" })
chat:send_prompt_buf()

assert(
	vim.wait(5000, function()
		return s.chat.state == "ready"
	end, 10),
	"explicit resume did not become ready"
)
assert(s.chat.resumed, "explicit resume did not load the conversation")
assert(s.chat.draft == nil or table.concat(s.chat.draft, "") == "", "resume command remained in draft")

sessions.stop(s)
vim.fn.delete(dir, "rf")
print("stopped history: ok")
vim.cmd("qa!")
