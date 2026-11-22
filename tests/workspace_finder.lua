-- Run: nvim --headless -u NONE -l tests/workspace_finder.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
vim.fn.writefile({ "hidden from folder browser" }, directory .. "/file.txt")
require("aero.config").setup({ workspace_finder = { home = directory } })
local finder = require("aero.workspace_finder")
local path = assert(finder.create(directory, "new repo"))
local second = assert(finder.create(directory, "second repo"))

assert(vim.fn.isdirectory(path .. "/.git") == 1)
assert(not finder.create(directory, "new repo"))
assert(not finder.create(directory, "../escape"))

local selected
local f = finder.open(function(value)
	selected = value
	return true
end)

assert(#f.entries == 2 and f.entries[1].name == "new repo")

vim.cmd("normal l")

assert(f.directory == path)

vim.cmd("normal h")

assert(f.directory == directory)

vim.cmd("normal y")

assert(#f.staged == 1)
assert(selected == nil)

vim.api.nvim_win_set_cursor(f.win, { 2, 0 })
vim.cmd("normal y")

assert(#f.staged == 2)

local renamed = directory .. "/renamed repo"
vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, { "  renamed repo/" })
vim.cmd.write()

assert(selected == nil)
assert(#f.staged == 2)
assert(vim.fn.isdirectory(renamed .. "/.git") == 1)
assert(vim.fn.isdirectory(path) == 0)
assert(f.staged[1].path == renamed or f.staged[2].path == renamed)

vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, { "  second repo/" })
vim.cmd.write()

assert(vim.fn.isdirectory(renamed .. "/.git") == 1)
assert(vim.fn.isdirectory(second .. "/.git") == 1)

vim.api.nvim_buf_set_lines(f.buf, 0, 1, false, { "  renamed repo/" })

vim.cmd("normal q")

assert(selected == second)
assert(#f.staged == 0)
assert(not vim.api.nvim_win_is_valid(f.win))

local cancelled = finder.open(function()
	error("cancel registered a workspace")
end)
vim.cmd("normal q")

assert(not vim.api.nvim_win_is_valid(cancelled.win))

vim.fn.delete(directory, "rf")
print("workspace finder: ok")
