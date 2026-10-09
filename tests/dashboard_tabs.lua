-- Run from the repository root: nvim --headless -u NONE -l tests/dashboard_tabs.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/worktree", "p")
local worktree = vim.fn.resolve(dir .. "/worktree")
require("aero").setup({ state_file = dir .. "/state.json", animation = false, fullscreen_key = false })
local dashboard = require("aero.dashboard")
local tabs = require("aero.tabs")

local original = api.nvim_get_current_tabpage()
dashboard.open()
assert(not tabs.enter(worktree), "dashboard-only tab should be reused")
assert(api.nvim_get_current_tabpage() == original and #api.nvim_list_tabpages() == 1)
assert(vim.t.aero_worktree == worktree)
assert(vim.fn.getcwd(-1, 0) == worktree, "reused tab must adopt the worktree directory")

-- An existing worktree tab takes precedence over another dashboard-only tab.
vim.cmd.tabnew()
dashboard.open()
assert(not tabs.enter(worktree))
assert(api.nvim_get_current_tabpage() == original)
assert(#api.nvim_list_tabpages() == 2)

-- A dashboard alongside editing work must not be repurposed.
vim.cmd.tabnext()
dashboard.close()
vim.cmd.enew()
api.nvim_buf_set_lines(0, 0, -1, false, { "unsaved work" })
dashboard.open()
local editing = api.nvim_get_current_tabpage()
vim.fn.mkdir(dir .. "/other", "p")
assert(tabs.enter(dir .. "/other"), "tab containing editing work must be preserved")
assert(api.nvim_get_current_tabpage() ~= editing)
assert(not vim.t[editing].aero_worktree)

-- A manually renamed folder leaves a stale path until Git's metadata is repaired.
local current = api.nvim_get_current_tabpage()
local cwd = vim.fn.getcwd()
local count = #api.nvim_list_tabpages()
local assigned = vim.t.aero_worktree
assert(vim.fn.rename(worktree, dir .. "/renamed") == 0)
local notify = vim.notify
local message
vim.notify = function(msg)
	message = msg
end
assert(tabs.enter(worktree) == nil)
assert(dashboard.open_worktree(worktree, function()
	error("missing checkout must not invoke the opener")
end) == nil)
require("aero.config").options.worktree_tabs = false
assert(dashboard.open_worktree(worktree) == nil)
vim.notify = notify
assert(message:find("git worktree repair", 1, true))
assert(api.nvim_get_current_tabpage() == current)
assert(#api.nvim_list_tabpages() == count)
assert(vim.fn.getcwd() == cwd and vim.t.aero_worktree == assigned)

vim.fn.delete(dir, "rf")
print("Dashboard tab reuse tests passed.")
