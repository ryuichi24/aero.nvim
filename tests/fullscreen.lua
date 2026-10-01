-- Run from the repository root: nvim --headless -u NONE -l tests/fullscreen.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	terminal = { cmd = { "cat" } },
	agents = {
		fixture = { type = "acp", cmd = { "python3", "tests/fixtures/acp.py", "save" } },
		pty = { cmd = { "cat" }, resume = { "cat" } },
	},
})
vim.cmd.runtime("plugin/aero.lua")
local api = vim.api
local fullscreen = require("aero.fullscreen")
local entered, exited = 0, 0
require("aero").on("fullscreen_entered", function()
	entered = entered + 1
end)
require("aero").on("fullscreen_exited", function()
	exited = exited + 1
end)
local panel = require("aero.panel")
local sessions = require("aero.session")
local dashboard = require("aero.dashboard")
local terminal = require("aero.terminal")
local origin = api.nvim_get_current_tabpage()
local cwd = vim.fn.getcwd()
vim.t.aero_worktree = cwd
vim.cmd("vsplit")

local function layout()
	local out = {}
	for _, win in ipairs(api.nvim_tabpage_list_wins(origin)) do
		out[win] = { api.nvim_win_get_buf(win), api.nvim_win_get_width(win), api.nvim_win_get_height(win) }
	end
	return out
end
local function mapping(buf)
	local maps = vim.list_extend(api.nvim_buf_get_keymap(buf, "n"), api.nvim_get_keymap("n"))
	for _, map in ipairs(maps) do
		if map.lhs == "gF" then
			return true
		end
	end
	return false
end
local function zoom(win, kind, count)
	api.nvim_set_current_win(win)
	local before, tabs = layout(), #api.nvim_list_tabpages()
	assert(mapping(api.nvim_win_get_buf(win)), "missing fullscreen mapping")
	vim.cmd("Aero fullscreen")
	assert(fullscreen.active().kind == kind)
	assert(#api.nvim_tabpage_list_wins(0) == count)
	assert(#api.nvim_list_tabpages() == tabs + 1)
	assert(vim.fn.getcwd() == cwd)
	assert(require("aero.tabs").find(cwd) == origin, "fullscreen claimed the worktree tab")
	assert(api.nvim_win_get_width(api.nvim_get_current_win()) == vim.o.columns)
	return function()
		vim.cmd("Aero fullscreen")
		assert(api.nvim_get_current_tabpage() == origin)
		assert(api.nvim_get_current_win() == win)
		assert(#api.nvim_list_tabpages() == tabs)
		assert(
			vim.deep_equal(layout(), before),
			"original layout changed: " .. vim.inspect({ before = before, after = layout() })
		)
	end
end

local code = api.nvim_get_current_win()
api.nvim_buf_set_lines(0, 0, -1, false, { "middle pane" })
local restore_code = zoom(code, "editor", 1)
assert(api.nvim_get_current_buf() == api.nvim_win_get_buf(code))
api.nvim_buf_set_lines(0, 0, -1, false, { "edited while fullscreen" })
restore_code()
assert(api.nvim_buf_get_lines(0, 0, -1, false)[1] == "edited while fullscreen")

dashboard.open()
local dw = api.nvim_get_current_win()
zoom(dw, "dashboard", 1)()
zoom(dw, "dashboard", 1)
dashboard.close()
assert(api.nvim_get_current_tabpage() == origin)

local pty = sessions.create(cwd, "pty")
assert(panel.show(pty))
local pw = panel.win()
zoom(pw, "agent", 1)()
assert(sessions.is_running(pty), "fullscreen restarted/stopped the terminal agent")

local tw = terminal.open(cwd, api.nvim_tabpage_list_wins(origin)[2])
vim.cmd.stopinsert()
zoom(tw, "terminal", 1)()
assert(vim.fn.jobwait({ vim.b[api.nvim_win_get_buf(tw)].terminal_job_id }, 0)[1] == -1)

local acp = sessions.create(cwd, "fixture")
assert(panel.show(acp))
assert(vim.wait(5000, function()
	return acp.chat.state == "ready"
end, 10))
acp.chat:compose()
vim.cmd.stopinsert()
local prompt = api.nvim_get_current_win()
local draft = { "keep this unsent draft" }
api.nvim_buf_set_lines(acp.chat.prompt_buf, 0, -1, false, draft)
zoom(prompt, "agent", 2)()
assert(vim.deep_equal(api.nvim_buf_get_lines(acp.chat.prompt_buf, 0, -1, false), draft))

-- A prompt first opened in fullscreen still targets the original running ACP session.
api.nvim_win_close(prompt, false)
local exit = zoom(panel.win(), "agent", 1)
assert(panel.win() == api.nvim_get_current_win())
require("aero").prompt()
vim.cmd.stopinsert()
assert(api.nvim_get_current_buf() == acp.chat.prompt_buf)
assert(#api.nvim_tabpage_list_wins(0) == 2)
exit()
assert(sessions.is_running(acp))

-- Closing a fullscreen tab manually also leaves the original panel usable.
zoom(panel.win(), "agent", 1)
vim.cmd.tabclose()
assert(api.nvim_get_current_tabpage() == origin)
assert(fullscreen.active() == nil)
zoom(panel.win(), "agent", 1)()
assert(
	vim.wait(1000, function()
		return entered == exited
	end, 10),
	"fullscreen exit event missing or duplicated"
)

sessions.delete(acp)
sessions.delete(pty)
terminal.delete(cwd)
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print("Fullscreen tests passed (code, dashboard, agent, ACP prompt, worktree terminal).")
