-- Run: nvim --headless -u NONE -l tests/todo_notifications.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local notifications = require("aero.acp.todo_notifications")
local function chat(name)
	return { buf = api.nvim_create_buf(false, true), s = { name = name }, blocks = {} }
end
local function update(c, status)
	c.blocks = { { kind = "plan", entries = { { content = "Implement feature", status = status } } } }
	notifications.update(c)
end
local function popups()
	local result = {}
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if vim.bo[api.nvim_win_get_buf(win)].filetype == "aero_todos" then result[#result + 1] = win end
	end
	return result
end
local original = api.nvim_get_current_win()
local a, b = chat("OpenCode"), chat("Claude")
update(a, "in_progress")
update(b, "pending")
assert(#popups() == 2, "background sessions must have separate popups")
assert(api.nvim_get_current_win() == original, "notification stole focus")
local wins = popups()
local config = api.nvim_win_get_config(wins[1])
assert(config.title[1][1]:find("todos", 1, true))
notifications.close(a)
update(a, "in_progress")
assert(#popups() == 1, "duplicate snapshot reopened dismissed popup")
update(a, "completed")
assert(#popups() == 2, "state change did not reopen popup")
a.replaying = true
notifications.close(a)
update(a, "pending")
assert(#popups() == 1, "history replay generated a notification")
a.replaying = false
require("aero.config").options.acp.todo_notifications = false
update(a, "completed")
assert(#popups() == 1, "disabled notifications generated a popup")
require("aero.config").options.acp.todo_notifications = true
vim.cmd("tabnew")
assert(#popups() == 1, "notifications did not follow tab switch")
api.nvim_buf_delete(b.buf, { force = true })
assert(#popups() == 0, "deleted session left a popup")
api.nvim_buf_delete(a.buf, { force = true })

-- Every real update resets the deadline; focusing pauses it until leaving.
local c = chat("Timed")
require("aero.config").options.acp.todo_notification_timeout = 120
update(c, "pending")
vim.wait(70, function() return false end, 5)
update(c, "in_progress")
vim.wait(70, function() return false end, 5)
assert(#popups() == 1, "old deadline closed an updated popup")
assert(vim.wait(500, function() return #popups() == 0 end, 5), "popup did not auto-close")
assert(notifications.focus(), "expired popup could not be reopened")
assert(vim.bo.filetype == "aero_todos", "reopened popup was not focused")
api.nvim_set_current_win(original)
notifications.close(c)
update(c, "completed")
vim.cmd("runtime plugin/aero.lua")
vim.cmd("Aero todos")
assert(vim.bo.filetype == "aero_todos", "focus command did not enter popup")
vim.wait(180, function() return false end, 5)
assert(#popups() == 1, "focused popup timed out")
api.nvim_set_current_win(original)
assert(vim.wait(500, function() return #popups() == 0 end, 5), "leaving popup did not restart timeout")
require("aero.config").options.acp.todo_notification_timeout = 0
update(c, "pending")
vim.wait(180, function() return false end, 5)
assert(#popups() == 1, "zero timeout should keep popup open")
notifications.close(c)
require("aero.config").options.acp.todo_notification_timeout = 120
update(c, "in_progress")
notifications.close(c)
require("aero.config").options.acp.todo_notification_timeout = 0
update(c, "completed")
vim.wait(180, function() return false end, 5)
assert(#popups() == 1, "dismissed popup timer closed its replacement")
api.nvim_buf_delete(c.buf, { force = true })

local d = chat("Human-readable title")
d.blocks = { { kind = "tool", title = "Update task list", status = "pending",
	rawInput = { todos = { { content = "First item", status = "pending" } } } } }
notifications.update(d)
assert(#popups() == 1, "first todo tool input did not show a notification")
api.nvim_buf_delete(d.buf, { force = true })
print("todo notification tests passed")
vim.cmd("qa!")
