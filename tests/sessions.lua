-- Run: nvim --headless -u NONE -l tests/sessions.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/one", "p")
vim.fn.mkdir(dir .. "/two", "p")
require("aero").setup({ state_file = dir .. "/state.json", animation = false, start_insert = false })
vim.cmd.runtime("plugin/aero.lua")
local session = require("aero.session")
local one = assert(session.create(dir .. "/one", "claude", "first"))
local two = assert(session.create(dir .. "/two", "claude", "second"))
local another = assert(session.create(dir .. "/one", "claude", "other"))
assert(session.create(dir .. "/one", "claude", "stopped"))
for _, s in ipairs({ one, another, two }) do
	s.buf = api.nvim_create_buf(false, true)
	vim.b[s.buf].aero_session = s.key
	s.chat = {
		alive = function()
			return true
		end,
		status = function()
			return s == one and "idle" or "busy"
		end,
		activity = function()
			return s == two and "thinking" or nil
		end,
		model_title = function() end,
		mode_title = function() end,
	}
end
local function results()
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if api.nvim_win_get_config(win).focusable == false then
			return api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), win
		end
	end
end
vim.cmd("Aero sessions")
local search = api.nvim_get_current_buf()
local lines, list_win = results()
assert(#lines == 6 and lines[1]:find("/one") and lines[5]:find("/two"))
assert(lines[2]:find("first") and lines[3]:find("other") and lines[6]:find("thinking"))
assert(api.nvim_win_get_cursor(list_win)[1] == 2, "selected a heading")
local down = vim.fn.maparg("j", "n", false, true).callback
down()
assert(api.nvim_win_get_cursor(list_win)[1] == 3)
down()
assert(api.nvim_win_get_cursor(list_win)[1] == 6, "did not skip group heading")
down()
assert(api.nvim_win_get_cursor(list_win)[1] == 2, "did not wrap to first session")
local up = vim.fn.maparg("k", "n", false, true).callback
up()
assert(api.nvim_win_get_cursor(list_win)[1] == 6, "k did not select previous session")
assert(vim.fn.maparg("<Esc>", "i", false, true).rhs == "<Esc>", "insert Escape should leave filtering")
assert(vim.fn.maparg("<Esc>", "n", false, true).callback == nil, "normal Escape should not close")
assert(vim.fn.maparg("<C-c>", "i", false, true).callback == nil, "insert Ctrl-c should not close")
assert(vim.fn.maparg("q", "i", false, true).callback == nil, "insert q should be search text")
two.chat.activity = function()
	return "Running tests"
end
assert(vim.wait(1000, function()
	return results()[6]:find("Running tests", 1, true) ~= nil
end))
api.nvim_buf_set_lines(search, 0, -1, false, { "two tests" })
api.nvim_exec_autocmds("TextChangedI", { buffer = search })
assert(#results() == 2 and results()[1]:find("/two") and results()[2]:find("second"))
assert(api.nvim_win_get_cursor(list_win)[1] == 2)
local select = vim.fn.maparg("<CR>", "i", false, true).callback
select()
assert(vim.fn.resolve(vim.fn.getcwd()) == vim.fn.resolve(dir .. "/two"), "did not switch worktree")
assert(require("aero.panel").current_session() == two, "did not select session")
assert(api.nvim_get_current_win() == require("aero.panel").win(), "did not focus panel")
assert(not api.nvim_buf_is_valid(search), "search buffer leaked")
require("aero").sessions()
vim.fn.maparg("q", "n", false, true).callback()
assert(not results(), "popup leaked")
-- Avoid invoking real ACP shutdown on these test doubles.
one.chat, another.chat, two.chat = nil, nil, nil
vim.fn.delete(dir, "rf")
print("session popup: ok")
vim.cmd.qa({ bang = true })
