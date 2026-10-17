-- Run: nvim --headless -u NONE -l tests/context_sidebar.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/main", "p")
vim.fn.mkdir(dir .. "/source/folder", "p")
vim.fn.mkdir(dir .. "/source/folder/child", "p")
vim.fn.writefile({ "deep reference" }, dir .. "/source/folder/child/deep.txt")
vim.fn.writefile({ "reference" }, dir .. "/source/note.txt")
vim.fn.writefile({ "nested reference" }, dir .. "/source/folder/nested.txt")
dir = vim.fn.resolve(dir)
local main = dir .. "/main"
local git = require("aero.git")
git.list = function() return { { path = main, branch = "main" } } end
git.main_root = function() return main end
git.remote_status = function(_, callback) callback({}) end
require("aero").setup({
	state_file = dir .. "/state.json", animation = false, persist_buffers = false,
	worktree_tabs = false, context = { home = dir .. "/source", directory = dir .. "/context" },
})
vim.cmd.runtime("plugin/aero.lua")
require("aero.store").add_workspace(main)
local dashboard = require("aero.dashboard")
dashboard.open()
local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local function row(text)
	for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find(text, 1, true) then return i end
	end
end
local function action(text, key)
	api.nvim_set_current_win(win)
	api.nvim_win_set_cursor(win, { assert(row(text), "missing row: " .. text), 0 })
	vim.cmd("normal " .. key)
end
action("main (main)", "l")
assert(row("Context") and row("Add +"))
local context = require("aero.context")
assert(context.transfer(main, {
	{ path = dir .. "/source/note.txt", action = "copy" },
	{ path = dir .. "/source/folder", action = "copy" },
}))
assert(row("note.txt") and row("folder/"), "transfers did not refresh sidebar")
action("note.txt", "h")
assert(api.nvim_win_get_cursor(win)[1] == row("Context"), "wrong parent for context item")
action("Context", "h")
assert(not row("note.txt") and not row("Add +"))
action("Context", "l")
assert(row("note.txt"))
local windows = #api.nvim_tabpage_list_wins(0)
action("folder/", "\r")
assert(api.nvim_get_current_win() == win and #api.nvim_tabpage_list_wins(0) == windows,
	"opening a context folder left the sidebar or created a window")
assert(row("nested.txt") and row("child/") and not row("deep.txt"))
action("child/", "l")
assert(row("deep.txt"))
action("deep.txt", "h")
assert(api.nvim_win_get_cursor(win)[1] == row("child/"), "nested item did not move to its parent")
action("child/", "h")
assert(not row("deep.txt") and row("nested.txt"))
action("child/", "h")
assert(api.nvim_win_get_cursor(win)[1] == row("folder/"))
action("folder/", "h")
assert(not row("child/") and not row("nested.txt"))
action("note.txt", "\r")
assert(api.nvim_buf_get_name(0) == dir .. "/context/note.txt")
local note_buf = api.nvim_get_current_buf()
local input = require("aero.input")
local old_input = input.input
local function rename(text, name)
	input.input = function(opts, callback)
		assert(opts.default and opts.prompt == "Rename context item: ")
		callback(name)
	end
	action(text, "N")
end
rename("note.txt", "renamed.txt")
assert(row("renamed.txt") and not row("note.txt"))
assert(api.nvim_buf_get_name(note_buf) == dir .. "/context/renamed.txt")
rename("renamed.txt", nil)
assert(row("renamed.txt"), "cancelled rename changed the item")
rename("renamed.txt", "note.txt")
action("folder/", "l")
action("child/", "l")
rename("folder/", "renamed-folder")
assert(row("renamed-folder/") and row("deep.txt"), "folder rename lost nested expansion")
assert(vim.fn.filereadable(dir .. "/context/renamed-folder/child/deep.txt") == 1)
rename("renamed-folder/", "folder")
local old_notify = vim.notify
vim.notify = function() end
rename("note.txt", "folder")
assert(row("note.txt") and row("folder/"), "rename overwrote an existing item")
rename("note.txt", "../outside.txt")
assert(row("note.txt") and vim.fn.filereadable(dir .. "/outside.txt") == 0)
vim.notify = old_notify
input.input = old_input
api.nvim_set_current_win(win)
vim.cmd("Aero collapse context")
assert(not row("note.txt") and row("Reports"))
action("Context", "l")
action("Add +", "\r")
assert(vim.bo.filetype == "aero_context")
local function border_text(chunks)
	local text = ""
	for _, chunk in ipairs(chunks) do text = text .. chunk[1] end
	return text
end
local finder_config = api.nvim_win_get_config(0)
assert(border_text(finder_config.title):find("target: main", 1, true))
assert(border_text(finder_config.footer):find(main, 1, true))
vim.cmd("normal l") -- enter the source folder; target must remain visible
assert(border_text(api.nvim_win_get_config(0).footer):find(main, 1, true))
vim.cmd("normal q")
vim.wait(10)
local old_confirm = vim.fn.confirm
vim.fn.confirm = function(_, _, default)
	assert(default == 2)
	return 2
end
action("note.txt", "d")
assert(row("note.txt") and vim.fn.filereadable(dir .. "/context/note.txt") == 1)
vim.fn.confirm = function() return 1 end
action("note.txt", "d")
assert(not row("note.txt") and vim.fn.filereadable(dir .. "/context/note.txt") == 0)
action("folder/", "d")
assert(not row("folder/") and vim.fn.isdirectory(dir .. "/context/folder") == 0)
assert(vim.fn.filereadable(dir .. "/source/note.txt") == 1)
assert(vim.fn.filereadable(dir .. "/source/folder/nested.txt") == 1)
assert(api.nvim_get_current_win() == win, "deletion changed sidebar focus")
vim.fn.confirm = old_confirm
vim.fn.delete(dir, "rf")
print("context sidebar: OK")
vim.cmd("qa!")
