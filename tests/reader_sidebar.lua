vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local aero = require("aero")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
aero.setup({ state_file = dir .. "/state.json", companion = { auto_start = false }, animation = false })
vim.t.aero_worktree = vim.fn.getcwd()
local reader = require("aero.reader")
local dashboard = require("aero.dashboard")
local source = api.nvim_get_current_buf()
api.nvim_buf_set_lines(source, 0, -1, false, { "source" })
local original = reader.attach(api.nvim_get_current_win())

-- A layout change can repurpose the reader's remembered window for the sidebar.
aero.open()
local sidebar = api.nvim_get_current_win()
local sidebar_buf = api.nvim_win_get_buf(sidebar)
api.nvim_win_set_buf(original, sidebar_buf)
api.nvim_win_close(sidebar, false)
dashboard.attach(original)

aero.reader("source")
assert(api.nvim_win_get_buf(original) == sidebar_buf, "Source replaced the sidebar")
assert(api.nvim_get_current_win() ~= original, "Source focused the sidebar")
assert(api.nvim_get_current_buf() == source, "Source lost its buffer")
assert(#api.nvim_tabpage_list_wins(0) == 2, "Source created an extra middle window")

-- Reopening the sidebar and selecting Source again must reuse the middle window.
for _ = 1, 2 do
	aero.close()
	aero.open()
	sidebar = api.nvim_get_current_win()
	aero.reader("source")
	assert(api.nvim_win_get_buf(sidebar) == sidebar_buf, "Source hid the reopened sidebar")
	assert(api.nvim_get_current_buf() == source)
	assert(#api.nvim_tabpage_list_wins(0) == 2, "Source duplicated the middle window")
end
vim.fn.delete(dir, "rf")
print("reader sidebar: ok")
vim.cmd("qa!")
