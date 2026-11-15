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

local sidebar = api.nvim_get_current_buf()
local context_ns = api.nvim_get_namespaces().AeroSidebarContext
local feature_row = api.nvim_win_get_cursor(0)[1]
api.nvim_win_set_cursor(0, { 1, 0 })
local marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 1 and marks[1][2] == feature_row - 1, "context followed the cursor")
assert(marks[1][4].sign_text == "> ", "active worktree lacks a persistent marker")
assert(vim.wo.signcolumn == "yes:1", "context gutter is not reserved")

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

-- A displayed conversation and pending permission are independent of selection.
local view = require("aero.dashboard.view")
local sessions = require("aero.session")
local panel = require("aero.panel")
local original_win, original_from_buf = panel.win, sessions.from_buf
local status = "waiting"
local conversation = { key = "visible", chat = {
	status = function()
		return status
	end,
} }
panel.win = function()
	return api.nvim_get_current_win()
end
sessions.from_buf = function()
	return conversation
end
local state = {
	buf = sidebar,
	items = {
		{ kind = "worktree", wt = { path = root } },
		{ kind = "session", session = conversation },
		{ kind = "session", session = { key = "background", chat = conversation.chat } },
	},
}
vim.t.aero_worktree = root
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 3, "missing worktree, conversation, or background attention cue")
assert(marks[2][4].sign_text == ">?", "active conversation hid pending attention")
assert(marks[3][4].sign_text == " ?", "background permission lacks an attention marker")

status = "idle"
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 2 and marks[2][4].sign_text == "> ", "resolved attention left stale markers")

panel.win = function()
	return nil
end
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 1 and marks[1][2] == 0, "hidden conversation remained marked as open")

panel.win, sessions.from_buf = original_win, original_from_buf
vim.fn.delete(dir, "rf")
print("sidebar current worktree: ok")
vim.cmd("qa!")
