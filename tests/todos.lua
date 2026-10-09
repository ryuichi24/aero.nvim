-- Run: nvim --headless -u NONE -l tests/todos.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local todos = require("aero.acp.todos")
require("aero.config").setup({})
require("aero.acp.render").setup_highlights()
local entries = {
	{ content = "Inspect source", status = "completed" },
	{ content = "Implement 100% of feature", status = "in_progress", priority = "high" },
	{ content = "Verify", status = "pending" },
	{ content = "Old approach", status = "cancelled" },
}
local buf = api.nvim_create_buf(false, true)
api.nvim_win_set_buf(0, buf)
local parent = api.nvim_get_current_win()
vim.wo[parent].winbar = "Original"
local chat = { buf = buf, blocks = { { kind = "plan", entries = entries } } }
todos.attach(chat)
assert(vim.wo[parent].winbar:find("Todos 1/4 completed", 1, true))
assert(vim.wo[parent].winbar:find("Implement 100%% of feature", 1, true), "winbar text was not escaped")
local rows = todos.rows(entries)
assert(rows[2].text:find("◉ Working · high", 1, true))
assert(rows[4].text:find("− Cancelled", 1, true))
-- An in-place tool update replaces the plan in the pinned summary.
local tool = { kind = "tool", title = "functions.todowrite", rawInput = { todos = { { content = "Done", status = "completed" } } } }
table.insert(chat.blocks, tool)
todos.update(chat)
assert(vim.wo[parent].winbar:find("Todos 1/1 completed", 1, true))
tool.status = "failed"
todos.update(chat)
assert(vim.wo[parent].winbar:find("Todos 1/4 completed", 1, true), "failed todo call replaced the plan")
tool.status = "completed"
tool.rawOutput = vim.json.encode({})
todos.update(chat)
assert(#todos.latest(chat) == 0, "empty output did not clear todos")
tool.rawOutput = nil
tool.rawInput = "{unfinished"
assert(todos.latest(chat) == entries, "malformed input replaced the last valid plan")
assert(todos.block({ kind = "tool", title = "bash", rawOutput = vim.json.encode(entries) }) == nil)
-- Winbar should follow buffer visibility, rather than leak into another session.
api.nvim_set_current_win(parent)
api.nvim_win_set_buf(parent, api.nvim_create_buf(false, true))
assert(not vim.wo[parent].winbar:find("Todos", 1, true), "todo summary leaked into another buffer")
api.nvim_win_set_buf(parent, buf)
assert(vim.wait(1000, function() return vim.wo[parent].winbar:find("Todos", 1, true) ~= nil end, 10))
chat.blocks = {}
todos.update(chat)
assert(vim.wo[parent].winbar == "Original", "no-plan session retained the todo summary: " .. vim.wo[parent].winbar)
api.nvim_buf_delete(buf, { force = true })
print("Todo tests passed (live summary, checklist rows, tool parsing, clearing, lifecycle).")
vim.cmd("qa!")
