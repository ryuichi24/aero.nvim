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

assert(#marks == 3 and marks[3][2] == feature_row - 1, "context followed the cursor")
assert(marks[3][4].sign_text == "> ", "active worktree lacks a persistent marker")
assert(vim.wo.signcolumn == "yes:1", "context gutter is not reserved")

aero.collapse("workspaces")
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 2, "collapsed workspace lost its context marker")
assert(api.nvim_buf_get_lines(sidebar, marks[2][2], marks[2][2] + 1, false)[1]:find("repo", 1, true))

api.nvim_win_set_cursor(0, { marks[1][2] + 1, 0 })
vim.fn.maparg("<CR>", "n", false, true).callback()
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 1, "collapsed Workspace section lost its context marker")
assert(api.nvim_buf_get_lines(sidebar, marks[1][2], marks[1][2] + 1, false)[1]:find("Workspace", 1, true))

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

-- General retains its context even when its conversation row is hidden.
state.items = { { kind = "general_group" } }
conversation.worktree = require("aero.general").directory()
panel.win = function()
	return api.nvim_get_current_win()
end
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 1 and marks[1][4].sign_text == "> ", "collapsed General lost its displayed conversation context")

panel.win = function()
	return nil
end
vim.t.aero_worktree = conversation.worktree
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 1, "General tab lost its context with the panel hidden")

vim.t.aero_worktree = root
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 0, "General retained a stale context after returning to a workspace")

-- Knowledge keeps its owning headings marked as descendants disappear.
conversation.worktree = require("aero.knowledge.store").directory() .. "/spaces/abc123"
vim.t.aero_worktree = conversation.worktree
state.items = {
	{ kind = "knowledge_group" },
	{ kind = "knowledge_collection", collection = { id = "def456" } },
	{ kind = "knowledge_space", space = { id = "abc123", collection_id = "def456" } },
}
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 3, "knowledge context did not mark its heading, collection, and space")

state.knowledge_catalog = { spaces = { { id = "abc123", collection_id = "def456" } } }
state.items[3] = nil
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 2, "collapsed knowledge collection lost its context")

state.items = { { kind = "knowledge_group" } }
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 1 and marks[1][4].sign_text == "> ", "collapsed Knowledge base lost its context")

vim.t.aero_worktree = root
panel.win = function()
	return api.nvim_get_current_win()
end
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 1, "displayed knowledge conversation did not mark Knowledge base")

panel.win = function()
	return nil
end
view.refresh_context(state)
marks = api.nvim_buf_get_extmarks(sidebar, context_ns, 0, -1, { details = true })

assert(#marks == 0, "Knowledge base retained a stale context")

panel.win, sessions.from_buf = original_win, original_from_buf
vim.fn.delete(dir, "rf")
print("sidebar current worktree: ok")
vim.cmd("qa!")
