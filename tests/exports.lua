-- Run: nvim --headless -u NONE -l tests/exports.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({ exports = { location = "worktree", worktree_dir = "logs" }, acp = { max_tool_lines = 1 } })
local exports = require("aero.exports")
local chat = {
	s = { name = "Test chat", agent = "fixture", worktree = dir },
	session_id = "conversation",
	agent_title = function()
		return "Fixture"
	end,
	blocks = {
		{ kind = "user", text = "Question" },
		{ kind = "agent", text = "Complete streaming text", shown = 2 },
		{
			kind = "tool",
			id = "tool",
			status = "completed",
			rawInput = { secret_detail = "input" },
			content = { { type = "content", content = { type = "text", text = "first\nsecond\nthird" } } },
			rawOutput = "raw detail",
		},
	},
}
vim.ui.select = function(_, _, callback)
	callback("Keep original only")
end
local first = exports.export(chat)
assert(first and vim.uv.fs_stat(first))
local text = table.concat(vim.fn.readfile(first), "\n")
assert(text:find("Complete streaming text", 1, true))
assert(text:find("first\nsecond\nthird", 1, true))
assert(not text:find("more lines", 1, true))
assert(text:find("secret_detail", 1, true) and text:find("raw detail", 1, true))
assert(chat.blocks[2].shown == 2, "export mutated live reveal state")
assert(#exports.list(dir) == 1)
local second = exports.export(chat)
assert(first ~= second and #exports.list(dir) == 2, "repeated exports overwrite files")
require("aero.config").options.exports.location = "data"
assert(#exports.list(dir) == 2, "location change hid previous exports")
assert(exports.directory(dir):find("/Aero/exports/", 1, true))
require("aero.config").options.exports.location = "worktree"
require("aero.config").options.agents.fixture = {
	type = "acp",
	cmd = { "python3", vim.fn.getcwd() .. "/tests/fixtures/acp.py", "export" },
}
require("aero.config").options.exports.rewrite_instructions = "EXPORT_CUSTOM_PROMPT: Organize the transcript by topic."
vim.ui.select = function(_, _, callback)
	callback("Create AI-formatted copy")
end
local original = exports.export(chat)
local progress_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
	local cfg = vim.api.nvim_win_get_config(win)
	if cfg.relative == "editor" then
		progress_win = win
	end
end
assert(progress_win, "readable export has no live progress indicator")
local original_text = table.concat(vim.fn.readfile(original), "\n")
local readable = original:gsub("%.md$", "-readable.md")
assert(
	vim.wait(5000, function()
		return vim.uv.fs_stat(readable) ~= nil
	end, 10),
	"readable export timed out"
)
assert(table.concat(vim.fn.readfile(readable), "\n"):find("new answer", 1, true))
assert(#chat.blocks == 3, "formatting altered original conversation")
assert(not vim.api.nvim_win_is_valid(progress_win), "progress indicator remained after completion")
assert(table.concat(vim.fn.readfile(original), "\n") == original_text, "formatting altered archive")
vim.fn.delete(dir, "rf")
print("exports: ok")
vim.cmd("qa!")
