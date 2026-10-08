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
assert(vim.wo[parent].winbar:find("gT: list", 1, true))
todos.open(chat)
local popup = chat.todo_popup
local function text() return table.concat(api.nvim_buf_get_lines(popup.buf, 0, -1, false), "\n") end
assert(text():find("Working on: Implement 100% of feature", 1, true))
assert(text():find("◉ Working · high", 1, true))
assert(text():find("− Cancelled", 1, true))
assert(not vim.bo[popup.buf].modifiable)
-- An in-place tool update replaces the plan in the pinned summary and popup.
local tool = { kind = "tool", title = "functions.todowrite", rawInput = { todos = { { content = "Done", status = "completed" } } } }
table.insert(chat.blocks, tool)
todos.update(chat)
assert(text():find("Todos 1/1 completed", 1, true))
assert(not text():find("Working on:", 1, true))
tool.status = "failed"
todos.update(chat)
assert(text():find("Todos 1/4 completed", 1, true), "failed todo call replaced the plan")
tool.status = "completed"
tool.rawOutput = vim.json.encode({})
todos.update(chat)
assert(text():find("No current todos.", 1, true), "empty output did not clear todos")
tool.rawOutput = nil
tool.rawInput = "{unfinished"
assert(todos.latest(chat) == entries, "malformed input replaced the last valid plan")
assert(todos.block({ kind = "tool", title = "bash", rawOutput = vim.json.encode(entries) }) == nil)
-- Popup and winbar should follow buffer visibility, rather than leak into another session.
api.nvim_set_current_win(parent)
api.nvim_win_set_buf(parent, api.nvim_create_buf(false, true))
assert(vim.wait(1000, function() return chat.todo_popup == nil end, 10))
assert(not api.nvim_win_is_valid(popup.win))
assert(not vim.wo[parent].winbar:find("Todos", 1, true), "todo summary leaked into another buffer")
api.nvim_win_set_buf(parent, buf)
assert(vim.wait(1000, function() return vim.wo[parent].winbar:find("Todos", 1, true) ~= nil end, 10))
chat.blocks = {}
todos.update(chat)
assert(vim.wo[parent].winbar == "Original", "no-plan session retained the todo summary: " .. vim.wo[parent].winbar)
api.nvim_buf_delete(buf, { force = true })
vim.fn.writefile({ "Todo tests passed (live summary, popup, tool parsing, clearing, lifecycle)." }, "/dev/stdout")
vim.cmd("qa!")
