-- Run: nvim --headless -u NONE -l tests/sidebar_persistence.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.env.AERO_SIDEBAR_ROOT or vim.fn.tempname()
local worker = vim.env.AERO_SIDEBAR_ROOT ~= nil
vim.fn.mkdir(root, "p")
local aero = require("aero")
aero.setup({ state_file = root .. "/state.json", animation = false, companion = { auto_start = false } })
local store = require("aero.store")
require("aero.git").list = function()
	return { { path = root, branch = "main" } }
end
require("aero.git").remote_status = function() end
require("aero.session").list = function()
	return {}
end
require("aero.knowledge").catalog = function()
	return { collections = {}, spaces = {} }
end

if not worker then
	assert(store.add_workspace(root))
end

aero.open()
local api = vim.api
local buf = api.nvim_get_current_buf()

local function line(text)
	for row, value in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if value:find(text, 1, true) then
			return row, value
		end
	end
end

local function action(text, key)
	api.nvim_win_set_cursor(0, { assert(line(text), text), 0 })

	for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
		if map.lhs == key then
			map.callback()
			return
		end
	end

	error("missing mapping: " .. key)
end

if worker then
	assert(select(2, line("Workspace")):find("▸", 1, true))
	assert(select(2, line("General")):find("▸", 1, true))
	assert(select(2, line("Knowledge base")):find("▸", 1, true))

	action("Workspace", "l")

	assert(line("Reports"), "expanded worktree did not survive restart")
	assert(select(2, line("Reports")):find("▸", 1, true), "report fold did not survive restart")
	assert(store.data.sidebar.reference_folders_expanded[root] == true)
	assert(store.data.sidebar.knowledge_expanded["hidden"] == false)
	assert(store.data.sidebar.submodules_expanded[root] == true)
	assert(store.data.sidebar.repositories_expanded[root] == false)

	-- A separate instance's changes must survive a local fold edit.
	assert(store.set_sidebar({ knowledge_expanded = { concurrent = false } }))

	action("Reports", "l")

	assert(store.data.sidebar.knowledge_expanded.concurrent == false)

	aero.close()
	vim.cmd("qa!")
	return
end

action("main", "l")
action("Reports", "h")
action("General", "h")
action("Knowledge base", "h")
action("Workspace", "h")

assert(store.set_sidebar({
	reference_folders_expanded = { [root] = true },
	knowledge_expanded = { hidden = false },
	submodules_expanded = { [root] = true },
	repositories_expanded = { [root] = false },
}))

aero.close()
aero.open()

assert(select(2, line("General")):find("▸", 1, true), "reopening lost the General fold")

local result = vim.system(
	{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/sidebar_persistence.lua" },
	{
		env = { AERO_SIDEBAR_ROOT = root },
		text = true,
	}
)
	:wait(15000)

assert(result.code == 0, result.stderr .. result.stdout)
assert(store.load())
assert(store.data.sidebar.reports_expanded[root] == true, "other instance's expansion was lost")

-- Bulk collapse clears default-closed descendants as well as persisting closed headings.
aero.collapse()

assert(store.data.sidebar.general_open == false and store.data.sidebar.knowledge_open == false)
assert(store.data.sidebar.reference_folders_expanded[root] == nil)
assert(store.data.sidebar.submodules_expanded[root] == nil)
assert(store.data.sidebar.repositories_expanded[root] == nil)

aero.close()
require("aero.buffers").flush()
vim.fn.delete(root, "rf")
print("Sidebar persistence passed (reopen, fresh process, nested folds, concurrent edits, bulk collapse).")
