-- Run: nvim --headless -u NONE -l tests/inbox.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/one", "p")
vim.fn.mkdir(dir .. "/two", "p")
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = true,
	agents = {
		fixture = { type = "acp", cmd = { "python3", root .. "/tests/fixtures/acp.py", "inbox" } },
		permission = { type = "acp", cmd = { "python3", root .. "/tests/fixtures/acp.py", "cancel" } },
	},
})
vim.cmd.runtime("plugin/aero.lua")
local sessions = require("aero.session")
local inbox = require("aero.inbox")
local panel = require("aero.panel")
local function wait(fn)
	assert(vim.wait(5000, fn, 10), "timed out")
end
local function results()
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if api.nvim_win_get_config(win).focusable == false then
			return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), win
		end
	end
end
local function key(name, mode)
	return assert(vim.fn.maparg(name, mode or "n", false, true).callback)
end
local one = assert(sessions.create(dir .. "/one", "fixture", "first"))
local two = assert(sessions.create(dir .. "/two", "permission", "second"))
assert(panel.show(one))
assert(panel.show(two))
wait(function()
	return one.chat.state == "ready" and two.chat.state == "ready"
end)
assert(#inbox.items() == 0, "startup created attention events")
assert(vim.tbl_contains(vim.fn.getcompletion("Aero in", "cmdline"), "inbox"))

-- Real ACP completion and failure; snapshot ticket context at event creation.
one.task_binding = { workspace = { root = dir }, ticket_id = "ticket-example" }
one.chat:prompt("first turn")
wait(function()
	return not one.chat.busy
end)
local completed = assert(inbox.items()[1])
assert(completed.kind == "completed" and completed.ticket == "ticket-example")
one.task_binding = nil
one.chat:prompt("fail")
wait(function()
	return not one.chat.busy
end)
local error = assert(inbox.items()[2])
assert(error.kind == "error" and error.text:find("inbox prompt failure", 1, true))
assert(not error.ticket and #inbox.items() == 2, "failed turn incorrectly completed")
for _ = 1, 3 do
	one.chat:changed()
end
inbox.add(one.chat, error.kind, error.block)
assert(#inbox.items() == 2, "repeated render/event duplicated entry")

-- Cross-worktree search and dismissal do not submit anything to the agent.
two.chat:prompt("hold")
wait(function()
	return two.chat.permission ~= nil
end)
local permission = assert(inbox.items()[3])
assert(permission.kind == "permission" and not permission.ticket)
vim.cmd("Aero inbox")
local search = api.nvim_get_current_buf()
local lines = results()
assert(table.concat(lines, "\n"):find("ticket-example", 1, true))
assert(lines[2]:find("permission", 1, true), "newest event not first")
assert(vim.fn.maparg("d", "i", false, true).callback == nil, "insert d should filter")
api.nvim_buf_set_lines(search, 0, -1, false, { "first error" })
api.nvim_exec_autocmds("TextChangedI", { buffer = search })
assert(#results() == 2 and results()[2]:find("inbox prompt failure", 1, true))
key("d")()
assert(error.dismissed and #inbox.items() == 2)
assert(results()[1] == "No matching attention events")
key("q")()
assert(not api.nvim_buf_is_valid(search))
inbox.add(one.chat, error.kind, error.block)
assert(#inbox.items() == 2, "dismissed event resurfaced")

-- Selecting a live permission focuses its options without choosing an answer.
vim.cmd("Aero inbox")
key("<CR>")()
wait(function()
	return api.nvim_get_current_buf() == two.chat.buf and api.nvim_win_get_cursor(0)[1] == two.chat:option_range()
end)
assert(two.chat.permission and two.chat.busy, "selection answered permission")
assert(permission.read and #inbox.items() == 1)
two.chat:cancel()
wait(function()
	return not two.chat.busy
end)
assert(#inbox.items() == 1, "cancelled turn created completion")
two.chat:prompt("hold")
wait(function()
	return two.chat.permission ~= nil
end)
assert(#inbox.items() == 2, "new permission did not appear")
two.chat:cancel()
wait(function()
	return not two.chat.busy
end)
assert(#inbox.items() == 1, "resolved unread permission remained actionable")

-- Completion opens the original turn, not the transcript tail or prompt draft.
vim.cmd("Aero inbox")
key("<CR>")()
wait(function()
	return api.nvim_get_current_buf() == one.chat.buf and api.nvim_get_current_line() == "## You"
end)
assert(completed.read and #inbox.items() == 0)
assert(not one.chat.busy, "opening completion submitted prompt")
one.chat:prompt("another turn")
wait(function()
	return not one.chat.busy
end)
assert(#inbox.items() == 1, "later turn was suppressed")
vim.cmd("Aero inbox")
key("r")()
assert(#inbox.items() == 0 and results()[1] == "No matching attention events")
one.chat:prompt("live event")
wait(function()
	return not one.chat.busy and results()[2] and results()[2]:find("completed", 1, true)
end)
key("d")()
assert(#inbox.items() == 0)
key("q")()

local notify = vim.notify
local empty_message
vim.notify = function(message)
	empty_message = message
end
vim.cmd("Aero inbox")
vim.notify = notify
assert(empty_message == "Aero: no attention events" and not results(), "empty inbox was unclear")

-- Exited transcripts open without restarting the process.
one.chat:prompt("exit")
wait(function()
	return one.chat.state == "exited"
end)
local exit_event
for _, e in ipairs(inbox.items()) do
	if e.text:find("agent exited (3)", 1, true) then
		exit_event = e
	end
end
assert(exit_event, "nonzero exit missing from inbox")
local old_chat = one.chat
inbox.select(exit_event)
wait(function()
	return api.nvim_get_current_line():find("agent exited (3)", 1, true)
end)
assert(one.chat == old_chat and old_chat.state == "exited", "inbox restarted exited agent")

-- Missing worktrees leave the event unread and do not change the current checkout.
two.chat:fail("missing checkout", { message = "test" })
local missing
for _, e in ipairs(inbox.items()) do
	if e.session == two then
		missing = e
	end
end
assert(missing)
local worktree, cwd = two.worktree, vim.fn.getcwd()
two.worktree = dir .. "/missing"
inbox.select(missing)
assert(not missing.read and vim.fn.getcwd() == cwd)
two.worktree = worktree
inbox.dismiss(missing)

-- Unavailable buffers are handled without marking the event read.
two.chat:fail("unavailable", { message = "test" })
local unavailable
for _, e in ipairs(inbox.items()) do
	if e.session == two then
		unavailable = e
	end
end
assert(unavailable)
local two_chat = two.chat
api.nvim_buf_delete(two.chat.buf, { force = true })
inbox.select(unavailable)
assert(not unavailable.read)
inbox.dismiss(unavailable)

-- Replay does not create events, and replacement drops obsolete events.
local count = #inbox.items()
old_chat.replaying = true
old_chat:info("historical failure", "error")
old_chat.replaying = false
assert(#inbox.items() == count)
one.chat = nil
for _, e in ipairs(inbox.items()) do
	assert(e.session ~= one)
end
one.chat = old_chat
two_chat:stop()
wait(function()
	return two_chat.state == "exited"
end)
vim.fn.delete(dir, "rf")
print("attention inbox: ok")
vim.cmd.qa({ bang = true })
