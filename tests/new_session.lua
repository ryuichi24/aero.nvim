vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local aero = require("aero")
aero.setup({
	state_file = dir .. "/state.json",
	animation = false,
	prompt_session_name = false,
	companion = { auto_start = false },
})
vim.cmd("runtime plugin/aero.lua")
local session = require("aero.session")
local navigation = require("aero.navigation")
local created, opened, selection
local create = session.create
session.create = function(path, agent, name)
	created = { path = path, agent = agent, name = name }
	return { worktree = path, agent = agent }
end
navigation.open_session = function(s, how)
	opened = { session = s, how = how }
end
vim.ui.select = function(items, opts, callback)
	assert(vim.tbl_contains(items, "opencode-acp"))
	assert(opts.prompt:find("New agent for", 1, true))
	selection = callback
end
local count = #api.nvim_tabpage_list_wins(0)
vim.cmd("Aero new")
assert(not created, "opening the picker created a session")
selection(nil)
assert(not created, "cancelling created a session")
vim.cmd("Aero new")
selection("opencode-acp")
assert(created.path == vim.fn.getcwd() and created.agent == "opencode-acp")
assert(opened.session.worktree == created.path and opened.how == "default")
vim.t.aero_worktree = dir
aero.new()
selection("default", 1)
assert(created.path == dir and created.agent == require("aero.config").options.default_agent)
assert(#api.nvim_tabpage_list_wins(0) == count, "new command opened the sidebar")
session.create = create
vim.fn.delete(dir, "rf")
print("new session: ok")
vim.cmd("qa!")
