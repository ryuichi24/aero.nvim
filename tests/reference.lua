-- Run: nvim --headless -u NONE -l tests/reference.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/source/folder/nested", "p")
vim.fn.mkdir(dir .. "/source/z-folder", "p")
vim.fn.mkdir(dir .. "/worktree", "p")
vim.fn.writefile({ "reference" }, dir .. "/source/folder/nested/note.txt")
vim.fn.writefile({ "move me" }, dir .. "/source/cut.txt")
vim.fn.writefile({ "leave me" }, dir .. "/source/unsaved.txt")
local setup_config = require("aero.config")
setup_config.setup({
	context = { home = "legacy-home" },
	companion = { context = { roots = false, allow_cut = false } },
})
assert(setup_config.options.reference_finder.home == "legacy-home")
assert(setup_config.options.companion.reference_finder.roots == false)
assert(setup_config.options.companion.reference_finder.allow_cut == false)
setup_config.setup({
	context = { home = "legacy-home" },
	reference_finder = { home = "canonical-home" },
	companion = { context = { roots = false }, reference_finder = { roots = {} } },
})
assert(setup_config.options.reference_finder.home == "canonical-home")
assert(
	vim.tbl_isempty(setup_config.options.companion.reference_finder.roots),
	"legacy settings bypassed deny-by-default roots"
)
setup_config.setup({ reference_finder = { home = dir .. "/source" } })
local reference = require("aero.reference")
local target = reference.directory(dir .. "/worktree")
assert(vim.startswith(target, vim.fn.stdpath("data") .. "/Aero/workspaces/"))
assert(target:match("/references$"))
assert(target ~= reference.directory(dir .. "/other-worktree"))
local legacy = vim.fs.joinpath(vim.fs.dirname(reference.directory(dir .. "/legacy-worktree")), "context")
vim.fn.mkdir(legacy, "p")
vim.fn.writefile({ "existing context reference" }, legacy .. "/saved.txt")
assert(reference.directory(dir .. "/legacy-worktree") == legacy, "existing reference storage was abandoned")
assert(reference.list(dir .. "/legacy-worktree")[1].name == "saved.txt")
local f = reference.open(dir .. "/worktree")
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
assert(
	f.entries[api.nvim_win_get_cursor(f.win)[1]].name == "z-folder",
	"parent navigation did not select exited folder"
)
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
local ok, err = reference.transfer(dir .. "/worktree", { { path = dir .. "/source/folder", action = "cut" } })
assert(not ok and err:match("already exists"))
assert(vim.fn.isdirectory(dir .. "/source/folder") == 1, "collision removed source")
local config = require("aero.config")
config.options.reference_finder.directory = ".aero/references"
ok, err = reference.transfer(dir .. "/source/folder", { { path = dir .. "/source/folder", action = "copy" } })
assert(not ok and err:match("inside source"))
config.options.reference_finder.directory = "data"
assert(#reference.list(dir .. "/worktree") == 2)
-- Reference selection targets the original session's draft and references an absolute path.
local picker, sessions, compose = require("aero.picker"), require("aero.session"), require("aero.compose")
local old_open, old_all, old_append = picker.open, sessions.all, compose.append
local selected = { worktree = dir .. "/worktree" }
local menu, attached
picker.open = function(opts)
	menu = opts
end
sessions.all = function()
	return { selected }
end
compose.append = function(s, text)
	assert(s == selected)
	attached = text
end
reference.pick(selected)
local items = menu.items()
assert(items[1].finder)
for _, item in ipairs(items) do
	if item.name == "folder" then
		menu.select(item)
	end
end
assert(attached:find(vim.json.encode(target .. "/folder"), 1, true))
assert(attached:find("folder", 1, true))
picker.open, sessions.all, compose.append = old_open, old_all, old_append
local completions = require("aero.acp.conversation").omnifunc(0, "/reference")
assert(completions[1].word == "/reference")
vim.wait(10)
vim.fn.delete(dir, "rf")
vim.fn.delete(target, "rf")
vim.fn.delete(legacy, "rf")
print("reference: OK")
vim.cmd("qa!")
