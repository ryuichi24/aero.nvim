vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(dir .. "/repo", "p")
vim.fn.mkdir(dir .. "/feature", "p")
local root, feature = dir .. "/repo", dir .. "/feature"
local git = require("aero.git")
git.list = function()
	return { { path = root, branch = "main" }, { path = feature, branch = "feature" } }
end
git.remote_status = function(_, callback)
	callback({})
end
local aero = require("aero")
aero.setup({ state_file = dir .. "/state.json", animation = false, companion = { auto_start = false } })
local store = require("aero.store")
store.add_workspace(root)
vim.t.aero_worktree = feature

local function selected_branch()
	return api.nvim_get_current_line()
end

aero.toggle()

assert(selected_branch():find("feature", 1, true), "toggle did not select the current worktree")

api.nvim_win_set_cursor(0, { 1, 0 })
aero.toggle()
vim.t.aero_worktree = root
aero.toggle()

assert(selected_branch():find("main", 1, true), "toggle restored the old cursor instead of the current worktree")

aero.collapse("workspaces")
aero.toggle()
vim.t.aero_worktree = feature
aero.toggle()

assert(selected_branch():find("feature", 1, true), "toggle did not reveal the worktree in a collapsed workspace")

aero.toggle()
vim.t.aero_worktree = dir .. "/unregistered"
aero.toggle()

assert(vim.bo.filetype == "Aero", "unregistered worktree prevented opening")

vim.fn.delete(dir, "rf")
print("sidebar current worktree: ok")
vim.cmd("qa!")
