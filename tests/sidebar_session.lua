vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.resolve(vim.fn.tempname())
local repo = dir .. "/repo"
vim.fn.mkdir(repo, "p")
assert(vim.system({ "git", "init", repo }, { text = true }):wait().code == 0)
local aero = require("aero")
aero.setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	companion = { auto_start = false },
	agents = { pty = { cmd = { "cat" }, resume = { "cat" } } },
})
local store = require("aero.store")
store.add_workspace(repo)
store.add_session(repo, "pty", nil, "stopped-agent")
local sessions = require("aero.session")
local stopped = assert(sessions.list(repo)[1])
assert(not sessions.is_running(stopped), "fixture session is already running")
local function sidebar_open()
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if vim.bo[api.nvim_win_get_buf(win)].filetype == "Aero" then
			return true
		end
	end
	return false
end

-- Start with an unrelated, non-empty editor so entering the session needs a new tab.
api.nvim_buf_set_name(0, dir .. "/startup.txt")
api.nvim_buf_set_lines(0, 0, -1, false, { "startup edits" })
aero.toggle()
local sidebar = api.nvim_get_current_win()
for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
	if line:find("stopped-agent", 1, true) then
		api.nvim_win_set_cursor(sidebar, { row, 0 })
		break
	end
end
vim.fn.maparg("<CR>", "n", false, true).callback()
assert(vim.t.aero_worktree == repo, "opening the session did not enter its worktree")
assert(sidebar_open(), "opening a stopped session hid the sidebar")
assert(require("aero.panel").current_session() == stopped, "the selected session was not shown")

-- Native quickfix navigation from a real agent terminal must reuse the editor,
-- including when the previously focused window was the quickfix list.
local agent_win = assert(require("aero.panel").win())
local agent_buf = api.nvim_win_get_buf(agent_win)
local editor = require("aero.navigation").code_window()
api.nvim_set_current_win(editor)
local first, second = api.nvim_create_buf(true, false), api.nvim_create_buf(true, false)
vim.fn.setqflist({ { bufnr = first, lnum = 1 }, { bufnr = second, lnum = 1 } })
vim.cmd.copen()
local count = #api.nvim_tabpage_list_wins(0)
api.nvim_set_current_win(agent_win)
vim.cmd.cnext()
assert(api.nvim_get_current_win() == editor and api.nvim_get_current_buf() == second)
api.nvim_set_current_win(vim.fn.getqflist({ winid = 0 }).winid)
api.nvim_set_current_win(agent_win)
vim.cmd.cprevious()
assert(api.nvim_get_current_win() == editor and api.nvim_get_current_buf() == first)
assert(api.nvim_win_get_buf(agent_win) == agent_buf, "quickfix replaced the agent terminal")
assert(#api.nvim_tabpage_list_wins(0) == count, "quickfix duplicated an agent window")
vim.cmd.cclose()

-- Session navigation from a hidden sidebar must keep it hidden.
aero.close()
vim.cmd("tabprevious")
aero.close()
require("aero.navigation").open_session(stopped, "default")
assert(not sidebar_open(), "session navigation reopened a hidden sidebar")
vim.fn.delete(dir, "rf")
print("sidebar stopped session: ok")
vim.cmd("qa!")
