vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/main", "p")
vim.fn.mkdir(root .. "/other", "p")
root = vim.fn.resolve(root)
vim.env.XDG_DATA_HOME = root .. "/data"
local main, other = root .. "/main", root .. "/other"
vim.fn.writefile({ "entry", "result" }, main .. "/source.lua")
vim.fn.writefile({ "other" }, other .. "/source.lua")
local git = require("aero.git")
git.list = function()
	return { { path = main, branch = "main" }, { path = other, branch = "other" } }
end
git.main_root = function()
	return main
end
git.remote_status = function(_, callback)
	callback({})
end
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	persist_buffers = false,
	worktree_tabs = false,
})
vim.cmd.runtime("plugin/aero.lua")
require("aero.store").add_workspace(main)
local dashboard = require("aero.dashboard")
local reading = require("aero.reading")
dashboard.open()
local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local function row(text)
	for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find(text, 1, true) then
			return i
		end
	end
end
local function action(text, key)
	api.nvim_set_current_win(win)
	api.nvim_win_set_cursor(win, { assert(row(text), "missing row: " .. text), 0 })
	vim.cmd("normal " .. key)
end
action("main (main)", "l")
action("other (other)", "l")
local binding = { worktree = main, session_key = "session" }
local args = { title = "Main tour", items = { { id = "entry", path = "source.lua", lnum = 1, label = "Entry" } } }
local result = assert(reading.publish(binding, args))
assert(row("Main tour"), "publication did not refresh sidebar")
assert(reading.publish({ worktree = other, session_key = "other" }, {
	title = "Other tour",
	items = { { id = "other", path = "source.lua", lnum = 1, label = "Other" } },
}))
assert(row("Main tour") < row("other (other)") and row("Other tour") > row("other (other)"))
action("Main tour", "h")
local header = api.nvim_win_get_cursor(win)[1]
assert(api.nvim_buf_get_lines(buf, header - 1, header, false)[1]:find("Reading lists", 1, true))
vim.cmd("normal h")
assert(not row("Main tour") and row("Other tour"), "section expansion leaked between worktrees")
vim.cmd("normal l")
assert(row("Main tour"))
require("aero.reader").select("source")
vim.bo.buftype = "acwrite" -- File browsers cannot host native quickfix jumps.
action("Main tour", "\r")
local context = vim.fn.getqflist({ context = 0 }).context
assert(context.worktree == main and context.reading_list_id == result.id)
assert(vim.bo.buftype == "quickfix")
local reader = require("aero.reader")
local quickfix_win = api.nvim_get_current_win()
assert(reader.active() == "reading", "opening the list did not prepare Reading for native jumps")
reader.select("reading")
local reading_win = api.nvim_get_current_win()
assert(reading_win ~= quickfix_win, "quickfix should remain a separate panel")
local window_count = #api.nvim_tabpage_list_wins(0)
api.nvim_set_current_win(quickfix_win)
vim.cmd.cfirst()
assert(api.nvim_get_current_win() == reading_win, "native quickfix jump opened outside Reading")
assert(#api.nvim_tabpage_list_wins(0) == window_count, "native quickfix jump created another window")
action("Main tour", "\r")
assert(api.nvim_get_current_win() == quickfix_win, "reopening replaced the quickfix panel")
assert(#api.nvim_tabpage_list_wins(0) == window_count)
reader.select("source")
reader.select("reading")
assert(api.nvim_get_current_win() == reading_win and vim.bo.buftype ~= "quickfix")
api.nvim_set_current_win(quickfix_win)
vim.cmd("normal \r")
assert(api.nvim_get_current_win() == reading_win, "item opened outside Reading")
assert(api.nvim_buf_get_name(0) == main .. "/source.lua")
assert(reader.active() == "reading")
assert(#api.nvim_tabpage_list_wins(0) == window_count, "item created another window")
assert(vim.bo[api.nvim_win_get_buf(quickfix_win)].buftype == "quickfix", "item replaced the quickfix panel")
vim.fn.setqflist({}, "a", { items = { { filename = main .. "/source.lua", lnum = 2, text = "Second" } } })
api.nvim_set_current_win(quickfix_win)
vim.cmd.cnext()
assert(api.nvim_get_current_win() == reading_win, "cnext opened outside Reading")
assert(#api.nvim_tabpage_list_wins(0) == window_count, "cnext created another window")
api.nvim_set_current_win(quickfix_win)
vim.cmd.cprevious()
assert(api.nvim_get_current_win() == reading_win, "cprevious opened outside Reading")
assert(#api.nvim_tabpage_list_wins(0) == window_count, "cprevious created another window")
reading.command("toggle")
local progress = false
for _, mark in
	ipairs(
		api.nvim_buf_get_extmarks(
			buf,
			api.nvim_create_namespace("Aero"),
			{ row("Main tour") - 1, 0 },
			{ row("Main tour") - 1, -1 },
			{ details = true }
		)
	)
do
	for _, chunk in ipairs(mark[4].virt_text or {}) do
		if chunk[1]:find("1/1 read", 1, true) then
			progress = true
		end
	end
end
assert(progress, "progress did not refresh sidebar")
assert(api.nvim_get_current_win() ~= win, "refresh stole focus")
args.id, args.title = result.id, "Renamed tour"
assert(reading.publish(binding, args))
assert(row("Renamed tour") and not row("Main tour"))
api.nvim_set_current_win(win)
vim.cmd("Aero collapse reading")
assert(not row("Renamed tour") and not row("Other tour"))
action("main (main)", "l") -- first child when already expanded
local first_header
for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
	if line:find("Reading lists", 1, true) then
		first_header = i
		break
	end
end
api.nvim_win_set_cursor(win, { first_header, 0 })
vim.cmd("normal l")
local new_row = first_header + 2
assert(api.nvim_buf_get_lines(buf, new_row - 1, new_row, false)[1]:find("New reading list +", 1, true))
vim.ui.input = function(_, callback)
	callback("Manual from sidebar")
end
api.nvim_win_set_cursor(win, { new_row, 0 })
vim.cmd("normal \r")
assert(vim.bo.filetype == "json")
assert(#reading.list(main) == 2 and #reading.list(other) == 1)
assert(row("Manual from sidebar"))
vim.fn.delete(root, "rf")
print("reading sidebar: ok")
