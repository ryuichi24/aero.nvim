-- Run: nvim --headless -u NONE -l tests/general.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({ state_file = dir .. "/state.json", animation = false })
local general = require("aero.general")
local sessions = require("aero.session")
local history = require("aero.history")
local store = require("aero.store")
vim.fn.mkdir(general.directory(), "p")
local s = sessions.create(general.directory(), "opencode-acp", "OAuth notes")
s.fresh = false
history.save(s, function()
	return { type = "acp", blocks = { { kind = "message", text = "refresh token expires" } }, draft = { "draft" } }
end)
history.flush(s)
local opts
require("aero.picker").open = function(value)
	opts = value
end
general.history()

assert(#opts.items() == 1)
assert(opts.search(s):find("refresh token expires", 1, true))
assert(opts.preview(s) == "refresh token expires")

opts.actions.p(s)
store.load()

assert(store.find_session(s.worktree, s.name).pinned)

opts.actions.a(s)

assert(#opts.items() == 0)

general.history(true)

assert(#opts.items() == 1)

local dashboard = require("aero.dashboard")
dashboard.open()
local original_tab = vim.api.nvim_get_current_tabpage()
general.show(s)

assert(s.chat and not s.chat:alive(), "browsing must not launch the agent")
assert(vim.api.nvim_get_current_tabpage() ~= original_tab, "general chat should use its dedicated tab")
assert(dashboard.is_open(), "the sidebar must follow general chats into their dedicated tab")
assert(s.chat.draft[1] == "draft")
assert(vim.uv.fs_realpath(vim.fn.getcwd()) == vim.uv.fs_realpath(general.directory()))

-- The sidebar lists unarchived general sessions separately and opens stopped logs.
store.set_session_field(s.worktree, s.name, "archived", false)
dashboard.open()
local api = vim.api
local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()

local function row(text)
	for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find(text, 1, true) then
			return i
		end
	end
end

local function action(text, key)
	api.nvim_set_current_win(win)
	api.nvim_win_set_cursor(win, { assert(row(text)), 0 })
	api.nvim_buf_call(buf, function()
		vim.fn.maparg(key, "n", false, true).callback()
	end)
end

assert(row("Workspace") and row("General") and row("OAuth notes"))
assert(row("New conversation +") and row("Search history"))

action("General", "h")

assert(not row("OAuth notes"))

action("General", "l")

assert(row("OAuth notes"))

action("OAuth notes", "h")

assert(api.nvim_win_get_cursor(win)[1] == row("General"))

action("OAuth notes", "<CR>")

assert(not s.chat:alive())
assert(vim.bo[buf].filetype == "Aero", "opening general history must retain the sidebar")
assert(dashboard.is_open(), "the sidebar must remain visible when reopening general history")

vim.api.nvim_set_current_tabpage(original_tab)
general.show(s)

assert(dashboard.is_open(), "the sidebar must remain visible when returning to an existing general tab")

sessions.stop(s)

-- General uses the workspace picker, including default resolution and naming.
local options = require("aero.config").options
options.default_agent = "opencode-acp"
options.prompt_session_name = true
local selected
general.show = function(value)
	selected = value
end
sessions.enter = function() end
require("aero.input").input = function(_, callback)
	callback("Named general chat")
end
vim.ui.select = function(agents, picker_options, callback)
	assert(agents[1] == "default")
	assert(vim.tbl_contains(agents, "opencode"), "match the workspace agent list")
	assert(picker_options.format_item("default") == "default (opencode-acp)")

	callback("default", 1)
end
general.new()

assert(selected and selected.agent == "opencode-acp")
assert(selected.name == "Named general chat")
assert(selected.worktree == general.directory())

vim.fn.delete(dir, "rf")
vim.cmd("qa!")
