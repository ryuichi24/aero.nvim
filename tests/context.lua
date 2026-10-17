-- Run: nvim --headless -u NONE -l tests/context.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/source/folder/nested", "p")
vim.fn.mkdir(dir .. "/source/z-folder", "p")
vim.fn.mkdir(dir .. "/worktree", "p")
vim.fn.writefile({ "reference" }, dir .. "/source/folder/nested/note.txt")
vim.fn.writefile({ "move me" }, dir .. "/source/cut.txt")
vim.fn.writefile({ "leave me" }, dir .. "/source/unsaved.txt")
require("aero.config").setup({ context = { home = dir .. "/source" } })
local context = require("aero.context")
local target = context.directory(dir .. "/worktree")
assert(vim.startswith(target, vim.fn.stdpath("data") .. "/Aero/workspaces/"))
assert(target:match("/context$"))
assert(target ~= context.directory(dir .. "/other-worktree"))
local f = context.open(dir .. "/worktree")
local function select(name, key)
	for row, item in ipairs(f.entries) do
		if item.name == name then
			api.nvim_win_set_cursor(f.win, { row, 0 })
			vim.cmd("normal " .. key)
			return
		end
	end
	error("missing entry " .. name)
end
select("folder", "y")
select("cut.txt", "d")
assert(#f.staged == 0 and vim.bo[f.buf].modified)
vim.cmd.write()
assert(#f.staged == 2 and not vim.bo[f.buf].modified)
assert(api.nvim_win_is_valid(f.stack_win))
assert(vim.fn.filereadable(dir .. "/source/cut.txt") == 1, "cut happened before exit")
assert(vim.fn.isdirectory(target) == 0, "transfer happened before exit")
select("folder", "l")
select("nested", "l")
assert(f.directory:match("/folder/nested$"))
vim.cmd("normal h")
vim.cmd("normal h")
select("z-folder", "l")
vim.cmd("normal h")
assert(f.entries[api.nvim_win_get_cursor(f.win)[1]].name == "z-folder", "parent navigation did not select exited folder")
select("z-folder", "l")
vim.cmd("normal -")
assert(f.entries[api.nvim_win_get_cursor(f.win)[1]].name == "z-folder", "- did not select exited folder")
select("unsaved.txt", "y")
vim.cmd("normal q")
assert(not api.nvim_win_is_valid(f.stack_win))
assert(vim.fn.readfile(target .. "/folder/nested/note.txt")[1] == "reference")
assert(vim.fn.filereadable(dir .. "/source/folder/nested/note.txt") == 1)
assert(vim.fn.filereadable(dir .. "/source/cut.txt") == 0)
assert(vim.fn.filereadable(target .. "/cut.txt") == 1)
assert(vim.fn.filereadable(target .. "/unsaved.txt") == 0)
local ok, err = context.transfer(dir .. "/worktree", { { path = dir .. "/source/folder", action = "cut" } })
assert(not ok and err:match("already exists"))
assert(vim.fn.isdirectory(dir .. "/source/folder") == 1, "collision removed source")
local config = require("aero.config")
config.options.context.directory = ".aero/context"
ok, err = context.transfer(dir .. "/source/folder", { { path = dir .. "/source/folder", action = "copy" } })
assert(not ok and err:match("inside source"))
config.options.context.directory = "data"
assert(#context.list(dir .. "/worktree") == 2)
-- Context selection targets the original session's draft and references an absolute path.
local picker, sessions, compose = require("aero.picker"), require("aero.session"), require("aero.compose")
local old_open, old_all, old_append = picker.open, sessions.all, compose.append
local selected = { worktree = dir .. "/worktree" }
local menu, attached
picker.open = function(opts) menu = opts end
sessions.all = function() return { selected } end
compose.append = function(s, text)
	assert(s == selected)
	attached = text
end
context.pick(selected)
local items = menu.items()
assert(items[1].finder)
for _, item in ipairs(items) do
	if item.name == "folder" then menu.select(item) end
end
assert(attached:find(vim.json.encode(target .. "/folder"), 1, true))
assert(attached:find("folder", 1, true))
picker.open, sessions.all, compose.append = old_open, old_all, old_append
local completions = require("aero.acp.conversation").omnifunc(0, "/context")
assert(completions[1].word == "/context")
vim.wait(10)
vim.fn.delete(dir, "rf")
vim.fn.delete(target, "rf")
print("context: OK")
vim.cmd("qa!")
