-- Run from the repository root: nvim --headless -u NONE -l tests/pane_resize.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local code = api.nvim_get_current_win()
local code_buf = api.nvim_get_current_buf()
local original_navigation = function() end
vim.keymap.set("n", "<C-w>k", original_navigation, { buffer = code_buf })
local aero = require("aero")
aero.setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	dashboard = { width = 20 },
	panel = { width = 30 },
	terminal = { height = 6, cmd = { "cat" } },
	acp = { prompt_height = 5 },
	agents = {
		fixture = { type = "acp", cmd = { "python3", "tests/fixtures/acp.py", "save" } },
		pty = { cmd = { "cat" }, resume = { "cat" } },
	},
})
local dashboard = require("aero.dashboard")
local panel = require("aero.panel")
local terminal = require("aero.terminal")
local sessions = require("aero.session")
local origin = api.nvim_get_current_tabpage()
local cwd = vim.fn.getcwd()
vim.t.aero_worktree = cwd
local function keys(sequence)
	api.nvim_feedkeys(api.nvim_replace_termcodes(sequence, true, false, true), "xt", false)
end
local function mapping(key)
	return vim.fn.maparg(key, "n", false, true)
end

-- Dashboard resizing must restore its original h/l tree actions afterwards.
dashboard.open()
local dw = api.nvim_get_current_win()
local collapse, expand = mapping("h").callback, mapping("l").callback
keys("<C-w>hhh<Esc>")
assert(api.nvim_win_get_width(dw) == 17, "dashboard repeat resizing failed")
assert(mapping("h").callback == collapse and mapping("l").callback == expand,
	"resize mode replaced dashboard navigation")
dashboard.close()
assert(require("aero.layout").dashboard_width() == 17,
	"stored dashboard width after close: " .. require("aero.layout").dashboard_width())
dashboard.open()
dw = api.nvim_get_current_win()
assert(api.nvim_win_get_width(dw) == 17, "dashboard width was not remembered: " .. api.nvim_win_get_width(dw))

-- Code panes get the same controls, without changing buffer contents.
api.nvim_set_current_win(code)
api.nvim_buf_set_lines(code_buf, 0, -1, false, { "keep the code intact" })
local width = api.nvim_win_get_width(code)
keys("<C-w>hhh<Esc>")
assert(api.nvim_win_get_width(code) == width - 3, "code pane repeat resizing failed")
assert(api.nvim_buf_get_lines(code_buf, 0, -1, false)[1] == "keep the code intact")
assert(mapping("<C-w>k").callback ~= original_navigation)

-- The same code buffer in an ordinary tab retains its original mappings.
vim.cmd.tabnew()
api.nvim_set_current_buf(code_buf)
assert(mapping("<C-w>k").callback == original_navigation,
	"Aero resizing leaked into a non-Aero tab")
vim.cmd.tabclose()
api.nvim_set_current_win(code)
assert(mapping("<C-w>k").callback ~= original_navigation,
	"returning to the Aero code pane did not restore resizing")

local shell = terminal.open(cwd, code)
vim.cmd.stopinsert()
keys("<C-w>kkk<Esc>")
assert(api.nvim_win_get_height(shell) == 9, "worktree shell repeat resizing failed")
local shell_buf = api.nvim_win_get_buf(shell)
local shell_job = vim.b[shell_buf].terminal_job_id
terminal.hide()
shell = terminal.open(cwd, code)
vim.cmd.stopinsert()
assert(api.nvim_win_get_height(shell) == 9, "shell height was not remembered")
assert(api.nvim_win_get_buf(shell) == shell_buf and vim.b[shell_buf].terminal_job_id == shell_job)
terminal.hide()

local acp = sessions.create(cwd, "fixture")
assert(panel.show(acp))
assert(vim.wait(5000, function()
	return acp.chat.state == "ready"
end, 10))
acp.chat:compose()
vim.cmd.stopinsert()
local prompt = api.nvim_get_current_win()
local transcript = panel.win()
api.nvim_set_current_win(transcript)
local height = api.nvim_win_get_height(transcript)
keys("<C-w>jjj<Esc>")
assert(api.nvim_win_get_height(transcript) == height - 3, "transcript repeat resizing failed")
assert(api.nvim_win_get_height(prompt) == 8, "resizing transcript did not adjust the prompt")
assert(require("aero.layout").prompt_height(acp.key) == 8,
	"resizing transcript did not remember the adjusted prompt height")

local pty = sessions.create(cwd, "pty")
assert(panel.show(pty))
api.nvim_set_current_win(panel.win())
vim.cmd.stopinsert()
local job = pty.job
width = api.nvim_win_get_width(0)
keys("<C-w>lll<Esc>")
assert(api.nvim_win_get_width(0) == width + 3, "terminal-agent repeat resizing failed")
assert(pty.job == job and sessions.is_running(pty), "resizing restarted the agent")

-- Both the prefix and repeated direction keys can be reconfigured in setup().
local opts = vim.deepcopy(require("aero.config").options)
opts.resize = { prefix = "g", keys = { grow = "u", shrink = "d", narrow = "b", widen = "f" } }
aero.setup(opts)
assert(mapping("<C-w>l").buffer ~= 1, "changing the prefix left an old resize mapping")
width = api.nvim_win_get_width(0)
keys("gfff")
assert(api.nvim_win_get_width(0) == width + 3, "custom prefix/repeat key did not widen the panel")
keys("bbb<Esc>")
assert(api.nvim_win_get_width(0) == width, "custom repeat key did not narrow the panel")
assert(mapping("f").buffer ~= 1 and mapping("b").buffer ~= 1, "custom repeat mappings were not restored")
api.nvim_set_current_win(code)
shell = terminal.open(cwd, code)
vim.cmd.stopinsert()
local height_before = api.nvim_win_get_height(shell)
keys("guuu")
assert(api.nvim_win_get_height(shell) == height_before + 3, "custom repeat key did not grow the shell")
keys("ddd<Esc>")
assert(api.nvim_win_get_height(shell) == height_before, "custom repeat key did not shrink the shell")
terminal.hide()
api.nvim_set_current_win(panel.win())

-- Reconfiguration disables shortcuts in existing panes and restores user mappings.
aero.setup({ state_file = dir .. "/state.json", animation = false, resize = false })
assert(mapping("<C-w>l").buffer ~= 1, "disabling resizing left a terminal-agent mapping")
assert(mapping("gf").buffer ~= 1, "disabling resizing left a custom mapping")
api.nvim_set_current_win(code)
assert(mapping("<C-w>k").callback == original_navigation, "disabling resizing lost a user mapping")
api.nvim_set_current_win(dw)
assert(mapping("<C-w>h").buffer ~= 1, "disabling resizing left a dashboard mapping")

sessions.delete(acp)
sessions.delete(pty)
terminal.delete(cwd)
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print("All-pane resize tests passed (dashboard, code, shell, transcript, agent terminal, mapping scope/restoration).")
