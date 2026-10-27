-- Run: nvim --headless -u NONE -i NONE -l tests/prompt_snippet_files.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({ state_file = dir .. "/state.json", animation = false })
vim.cmd.runtime("plugin/aero.lua")
local files = require("aero.prompt_snippet_files")
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind)
	return kind == "config" and dir .. "/config" or stdpath(kind)
end
local global = assert(files.create("global", dir, "review.json"))

assert(global == dir .. "/config/aero/prompt/review.jsonc")

local text = table.concat(vim.fn.readfile(global), "\n")
local data = require("aero.jsonc").decode(text)

assert(text:find("{{topic}} is a custom input variable, not a built-in", 1, true))
assert(#data == 1 and data[1].name == "review" and type(data[1].prompt) == "table")
assert(data[1].prompt[1]:find("{{topic}}", 1, true) and data[1].prompt[2] == "")

local context = require("aero.prompt_snippets").context({ s = { worktree = dir, name = "test" } }, "")

for variable in pairs(context) do
	assert(text:find("| {{" .. variable .. "}}", 1, true), "missing documentation for " .. variable)
end

assert(not files.create("global", dir, "review"), "overwrote existing file")
assert(table.concat(vim.fn.readfile(global), "\n") == text)

local workspace = assert(files.create("workspace", dir, "project"))

assert(workspace == dir .. "/.aero/prompt/project.jsonc")

local items, errors = require("aero.prompt_snippets").list(dir)

assert(#items == 2 and #errors == 0)
assert(items[1].scope == "workspace" and items[2].scope == "global")

for _, name in ipairs({ "", "../outside", "foo/bar", "foo\\bar", ".", "..", ".jsonc", "x\ny" }) do
	assert(not files.create("workspace", dir, name), "accepted invalid filename " .. name)
end

assert(not files.create("unknown", dir, "bad"))

vim.fn.writefile({ "[]" }, dir .. "/.aero/prompt/existing.json")

assert(not files.create("workspace", dir, "existing"), "shadowed existing JSON collection")

local select_ui, input_ui = vim.ui.select, vim.ui.input
local original_create = files.create
local captured
files.create = function(scope, worktree, name)
	captured = { scope = scope, worktree = worktree, name = name }
	return original_create(scope, worktree, name)
end
vim.t.aero_worktree = dir
vim.ui.select = function(choices, _, callback)
	assert(choices[1] == "global" and choices[2] == "workspace")

	callback("workspace")
end
vim.ui.input = function(_, callback)
	callback("interactive")
end
vim.cmd("Aero snippet")

assert(captured.scope == "workspace" and captured.worktree == dir and captured.name == "interactive")
assert(api.nvim_buf_get_name(0) == vim.fn.resolve(dir .. "/.aero/prompt/interactive.jsonc"))
assert(vim.bo.filetype == "jsonc")

captured = nil
vim.ui.select = function(_, _, callback)
	callback(nil)
end
vim.cmd("Aero snippet")

assert(captured == nil)

vim.ui.input = function(_, callback)
	callback(nil)
end
vim.cmd("Aero snippet workspace")

assert(captured == nil)

vim.cmd("Aero snippet global command-created")

assert(captured.scope == "global" and captured.name == "command-created")
assert(vim.fn.fnamemodify(api.nvim_buf_get_name(0), ":t") == "command-created.jsonc")
assert(vim.tbl_contains(vim.fn.getcompletion("Aero snippet ", "cmdline"), "workspace"))

files.create, vim.ui.select, vim.ui.input, vim.fn.stdpath = original_create, select_ui, input_ui, stdpath
vim.fn.delete(dir, "rf")
print("prompt snippet files: ok")
