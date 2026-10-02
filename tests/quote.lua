-- Run from the repository root: nvim --headless -u NONE -l tests/quote.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local file = dir .. "/example.lua"
local original = { "local alpha = 1", "local beta = 2", "return alpha + beta", "éclair 東京", "```nested fence" }
vim.fn.writefile(original, file)
local opts = {
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	agents = { fixture = { type = "acp", cmd = { "python3", root .. "/tests/fixtures/acp.py", "save" } } },
}
local aero = require("aero")
aero.setup(vim.deepcopy(opts))
vim.cmd.runtime("plugin/aero.lua")
vim.t.aero_worktree = dir
vim.cmd.tcd(vim.fn.fnameescape(dir))
vim.cmd.edit(vim.fn.fnameescape(file))
vim.bo.filetype = "lua"
local code, code_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local sessions = require("aero.session")
local panel = require("aero.panel")
local first = sessions.create(dir, "fixture")
assert(panel.show(first))
assert(vim.wait(5000, function()
	return first.chat.state == "ready"
end, 10))
local prompt = first.chat:get_prompt_buf()
api.nvim_buf_set_lines(prompt, 0, -1, false, { "Keep this draft." })
vim.fn.setreg('"', "untouched register")
local function select(win, mode, from, to)
	api.nvim_set_current_win(win)
	api.nvim_win_set_cursor(win, from)
	vim.cmd.normal({ args = { mode }, bang = true })
	api.nvim_win_set_cursor(win, to)
end
local function draft(s)
	return table.concat(api.nvim_buf_get_lines(s.chat.prompt_buf, 0, -1, false), "\n")
end
local function clear(s)
	api.nvim_buf_set_lines(s.chat:get_prompt_buf(), 0, -1, false, { "" })
end
select(code, "v", { 1, 6 }, { 1, 10 })
-- Exercise the installed default visual mapping, not just its callback.
api.nvim_feedkeys(api.nvim_replace_termcodes("<leader>aq", true, false, true), "xt", false)
assert(draft(first) == "Keep this draft.\n\nQuoted from example.lua (lines 1-1):\n\n```lua\nalpha\n```\n",
	"characterwise quote was incorrect: " .. draft(first))
assert(api.nvim_get_current_buf() == prompt, "quote did not focus the prompt")
assert(api.nvim_buf_get_name(code_buf) == vim.fn.resolve(file)
	and vim.deep_equal(api.nvim_buf_get_lines(code_buf, 0, -1, false), original))
assert(vim.fn.getreg('"') == "untouched register", "quoting changed the unnamed register")
assert(#first.chat.blocks == 0 and #first.chat.queue == 0, "quote submitted a prompt")

clear(first)
select(code, "V", { 3, 0 }, { 1, 0 })
aero.quote()
assert(draft(first):find(table.concat({ original[1], original[2], original[3] }, "\n"), 1, true),
	"reverse linewise quote lost lines")
assert(draft(first):find("lines 1-3", 1, true))

clear(first)
select(code, "\022", { 1, 6 }, { 2, 9 })
aero.quote()
assert(draft(first):find("\nalph\nbeta\n", 1, true), "blockwise quote was incorrect: " .. draft(first))

clear(first)
vim.o.selection = "exclusive"
select(code, "v", { 1, 6 }, { 1, 10 })
aero.quote()
assert(draft(first):find("\nalph\n", 1, true), "exclusive selection included the endpoint")
vim.o.selection = "inclusive"

clear(first)
select(code, "v", { 4, 0 }, { 4, 1 })
aero.quote()
assert(draft(first):find("\né\n", 1, true), "multibyte selection was corrupted")

clear(first)
select(code, "V", { 5, 0 }, { 5, 0 })
aero.quote()
assert(draft(first):find("````lua\n```nested fence\n````", 1, true), "embedded backticks broke the quote fence")

-- Selecting an older log must target its own session, not the panel's current session.
local second = sessions.create(dir, "fixture")
assert(panel.show(second))
assert(vim.wait(5000, function()
	return second.chat.state == "ready"
end, 10))
clear(first)
clear(second)
local log_win = api.nvim_open_win(first.buf, false, { split = "below", win = code, height = 4 })
vim.bo[first.buf].modifiable = true
api.nvim_buf_set_lines(first.buf, 0, -1, false, { "agent answer", "second line" })
vim.bo[first.buf].modifiable = false
select(log_win, "V", { 1, 0 }, { 2, 0 })
aero.quote()
assert(draft(first):find("Quoted from agent log: " .. first.name, 1, true))
assert(draft(first):find("\nagent answer\nsecond line\n", 1, true))
assert(draft(second) == "", "quoting a log went to another session")
assert(api.nvim_buf_get_lines(first.buf, 0, -1, false)[1] == "agent answer", "quoting edited the log")
api.nvim_win_close(log_win, false)

-- A hidden panel remembers which session should receive code quotes.
panel.close()
clear(first)
select(code, "V", { 2, 0 }, { 2, 0 })
aero.quote()
assert(draft(first):find(original[2], 1, true), "hidden panel lost the quote target")

-- Explicit command ranges quote full lines.
clear(first)
api.nvim_set_current_win(code)
vim.cmd("2,3Aero quote")
assert(draft(first):find(original[2] .. "\n" .. original[3], 1, true))

-- Change/disable the shortcut without losing existing drafts or a user's replacement.
opts.quote_key = "gq"
aero.setup(vim.deepcopy(opts))
assert(vim.fn.maparg("<leader>aq", "x", false, true).callback == nil)
assert(type(vim.fn.maparg("gq", "x", false, true).callback) == "function")
opts.quote_key = false
aero.setup(vim.deepcopy(opts))
assert(vim.fn.maparg("gq", "x", false, true).callback == nil)

-- A tab without a selected panel asks which local session should receive the quote.
local origin = api.nvim_get_current_tabpage()
vim.cmd.tabnew()
vim.t.aero_worktree = dir
api.nvim_set_current_buf(code_buf)
local picker_code = api.nvim_get_current_win()
local old_select = vim.ui.select
local first_draft, second_draft = draft(first), draft(second)
vim.ui.select = function(choices, _, callback)
	assert(#choices == 2)
	callback(nil)
end
select(picker_code, "V", { 1, 0 }, { 1, 0 })
aero.quote()
assert(draft(first) == first_draft and draft(second) == second_draft, "canceling the session picker changed a draft")
vim.ui.select = function(choices, _, callback)
	for _, s in ipairs(choices) do
		if s.key == second.key then
			return callback(s)
		end
	end
	error("session picker did not offer the target")
end
select(picker_code, "V", { 1, 0 }, { 1, 0 })
aero.quote()
assert(draft(second):find(original[1], 1, true), "session picker quote went to the wrong draft")
assert(draft(first) == first_draft)
vim.ui.select = old_select
vim.cmd.tabclose()
assert(api.nvim_get_current_tabpage() == origin)

-- No local session should leave source text and existing drafts alone.
vim.cmd.tabnew()
vim.t.aero_worktree = dir .. "/unregistered"
api.nvim_set_current_buf(code_buf)
local old_notify, warning = vim.notify
vim.notify = function(message)
	warning = message
end
select(api.nvim_get_current_win(), "V", { 1, 0 }, { 1, 0 })
aero.quote()
vim.notify = old_notify
assert(warning and warning:find("start an agent session", 1, true), "missing target was not reported")
assert(#api.nvim_tabpage_list_wins(0) == 1, "a missing target opened a panel")
assert(vim.deep_equal(api.nvim_buf_get_lines(code_buf, 0, -1, false), original))
vim.cmd.tabclose()

-- With panel=false, quoting opens the prompt alongside code rather than replacing it.
panel.close()
opts.panel = false
aero.setup(vim.deepcopy(opts))
clear(first)
select(code, "V", { 1, 0 }, { 1, 0 })
aero.quote()
assert(api.nvim_win_get_buf(code) == code_buf, "panel=false quoting replaced the code buffer")
assert(draft(first):find(original[1], 1, true))
assert(#first.chat.blocks == 0 and #second.chat.blocks == 0, "quoting submitted a message")

sessions.delete(second)
sessions.delete(first)
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print("Quote tests passed (visual modes, UTF-8, exclusive selection, drafts, logs, hidden/disabled panels, mappings, ranges).")
