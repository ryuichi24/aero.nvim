-- Run from the repository root: nvim --headless -u NONE -l tests/panel_resize.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	panel = { width = 40 },
	acp = { prompt_height = 8 },
	agents = { fixture = { type = "acp", cmd = { "python3", "tests/fixtures/acp.py", "save" } } },
})
local panel = require("aero.panel")
local sessions = require("aero.session")
local fullscreen = require("aero.fullscreen")
local origin = api.nvim_get_current_tabpage()
local cwd = vim.fn.getcwd()
local s = sessions.create(cwd, "fixture")
assert(panel.show(s))
assert(vim.wait(5000, function()
	return s.chat.state == "ready"
end, 10))
local function compose()
	s.chat:compose()
	vim.cmd.stopinsert()
	return api.nvim_get_current_win()
end
local prompt = compose()
assert(api.nvim_win_get_height(prompt) == 8)
assert(api.nvim_win_get_width(panel.win()) == 40)
assert(vim.fn.maparg("<C-s>", "n", false, true).nowait == 1,
	"normal-mode send no longer acts immediately")
assert(vim.fn.maparg("<C-s>", "i", false, true).nowait == 1,
	"insert-mode send no longer acts immediately")
-- Feed complete sequences to verify the Ctrl-w prefix and repeated directions.
local function keys(sequence)
	api.nvim_feedkeys(api.nvim_replace_termcodes(sequence, true, false, true), "xt", false)
end
keys("<C-w>k")
assert(api.nvim_win_get_height(prompt) == 9, "Ctrl-w k did not grow the prompt")
keys("<C-w>j")
assert(api.nvim_win_get_height(prompt) == 8, "Ctrl-w j did not shrink the prompt")
keys("<C-w>kkk")
assert(api.nvim_win_get_height(prompt) == 11, "repeated k did not grow the prompt")
keys("jj")
assert(api.nvim_win_get_height(prompt) == 9, "repeated j did not shrink the prompt")
keys("<C-w>lll")
assert(api.nvim_win_get_width(prompt) == 43, "repeated l did not widen the prompt")
assert(api.nvim_win_get_width(panel.win()) == 43, "horizontal resizing did not resize the panel column")
assert(require("aero.layout").panel_width() == 43, "horizontal resize did not remember the panel width")
keys("<C-w>hhh")
assert(api.nvim_win_get_width(prompt) == 40, "repeated h did not narrow the prompt")
keys("lkjh")
assert(api.nvim_win_get_width(prompt) == 40 and api.nvim_win_get_height(prompt) == 9,
	"mixed repeat keys did not resize both axes")
keys("<Esc>")
assert(vim.fn.maparg("j", "n", false, true).buffer ~= 1, "Esc did not leave resize mode")
assert(vim.fn.maparg("h", "n", false, true).buffer ~= 1, "Esc did not restore horizontal movement")
local custom_j = function() end
vim.keymap.set("n", "j", custom_j, { buffer = s.chat.prompt_buf })
keys("<C-w>k")
keys("0")
assert(vim.fn.maparg("j", "n", false, true).callback == custom_j,
	"leaving resize mode did not restore the original mapping")
vim.keymap.del("n", "j", { buffer = s.chat.prompt_buf })
keys("<C-w>j")
api.nvim_set_current_win(panel.win())
api.nvim_set_current_win(prompt)
assert(vim.fn.maparg("k", "n", false, true).buffer ~= 1, "leaving the prompt did not end resize mode")
vim.cmd("resize 12")
vim.cmd("vertical resize 55")
assert(api.nvim_win_get_height(prompt) == 12)
assert(api.nvim_win_get_width(panel.win()) == 55)
api.nvim_buf_set_lines(s.chat.prompt_buf, 0, -1, false, { "unsent draft" })
vim.cmd.close()
assert(api.nvim_win_get_width(panel.win()) == 55,
	"closing prompt changed panel width: " .. api.nvim_win_get_width(panel.win()))
prompt = compose()
assert(api.nvim_win_get_height(prompt) == 12, "closing the prompt lost its height")
assert(api.nvim_win_get_width(panel.win()) == 55,
	"reopening prompt changed panel width: " .. api.nvim_win_get_width(panel.win()))
assert(api.nvim_buf_get_lines(s.chat.prompt_buf, 0, -1, false)[1] == "unsent draft")
panel.close()
assert(require("aero.layout").panel_width() == 55,
	"stored width after close: " .. require("aero.layout").panel_width())
assert(panel.show(s))
assert(api.nvim_win_get_width(panel.win()) == 55,
	"hiding the panel lost its width: " .. api.nvim_win_get_width(panel.win()))
prompt = compose()
assert(api.nvim_win_get_height(prompt) == 12, "hiding the panel lost the prompt height")

-- Sending closes the prompt, but the next turn should keep its size.
s.chat:send_prompt_buf()
assert(vim.wait(5000, function()
	return not s.chat.busy
end, 10))
prompt = compose()
assert(api.nvim_win_get_height(prompt) == 12, "sending a message lost the prompt height")

-- Fullscreen uses the current height and leaves the original size untouched.
fullscreen.toggle()
assert(api.nvim_win_get_height(0) == 12, "fullscreen reset the prompt height")
vim.cmd("resize 16")
assert(api.nvim_win_get_height(0) == 16)
fullscreen.toggle()
assert(api.nvim_get_current_tabpage() == origin)
assert(api.nvim_get_current_win() == prompt)
assert(api.nvim_win_get_height(prompt) == 12, "fullscreen changed the original prompt")
vim.cmd.close()
assert(api.nvim_win_get_height(compose()) == 12, "fullscreen size leaked into the original tab")

-- Each tab has independent sizes, even when showing the same session.
vim.cmd.tabnew()
local other = api.nvim_get_current_tabpage()
assert(panel.show(s))
assert(api.nvim_win_get_width(panel.win()) == 40, "panel width leaked into another tab")
prompt = compose()
assert(api.nvim_win_get_height(prompt) == 8, "prompt height leaked into another tab")
vim.cmd("resize 10")
vim.cmd.close()
assert(api.nvim_win_get_height(compose()) == 10)
api.nvim_set_current_tabpage(origin)
assert(api.nvim_win_get_width(panel.win()) == 55)
assert(api.nvim_win_get_height(compose()) == 12)

-- Another session gets its initial height instead of inheriting the previous prompt.
local second = sessions.create(cwd, "fixture")
assert(panel.show(second))
assert(vim.wait(5000, function()
	return second.chat.state == "ready"
end, 10))
second.chat:compose()
vim.cmd.stopinsert()
assert(api.nvim_win_get_height(0) == 8, "prompt height leaked into another session")
assert(api.nvim_win_get_width(panel.win()) == 55)

sessions.delete(second)
sessions.delete(s)
api.nvim_set_current_tabpage(other)
vim.cmd.tabclose()
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print("Panel resize tests passed (native resizing, close/reopen, submission, fullscreen, per-tab/session sizes).")
