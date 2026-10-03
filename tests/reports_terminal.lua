-- Run from the repository root: nvim --headless -u NONE -l tests/reports_terminal.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
dir = vim.fn.resolve(dir)
local captured = dir .. "/pastes.json"
local report = dir .. "/.aero/reports/findings.md"
vim.fn.mkdir(vim.fs.dirname(report), "p")
vim.fn.writefile({ "Existing findings." }, report)
local aero = require("aero")
aero.setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	reports = { directory = "worktree" },
	agents = { fixture = { cmd = { "python3", root .. "/tests/fixtures/quote_terminal.py", captured } } },
})
vim.cmd.runtime("plugin/aero.lua")
local sessions, panel = require("aero.session"), require("aero.panel")
local s = sessions.create(dir, "fixture")
assert(panel.show(s))
assert(vim.wait(5000, function()
	return vim.fn.filereadable(captured) == 1
end, 10))
local job = s.job
api.nvim_set_current_win(panel.win())
vim.cmd("Aero report")
assert(vim.b.aero_report_picker)
assert(vim.deep_equal(api.nvim_buf_get_lines(0, 0, -1, false), { "  findings.md", "  New +" }))
api.nvim_win_set_cursor(0, { 1, 0 })
vim.fn.maparg("<CR>", "n", false, true).callback()
local received
assert(vim.wait(5000, function()
	local ok, data = pcall(vim.json.decode, table.concat(vim.fn.readfile(captured), "\n"))
	if ok and #data.pastes == 1 then
		received = data
		return true
	end
end, 10))
assert(received.pastes[1]:find(vim.json.encode(report), 1, true))
assert(received.pastes[1]:find("write or update", 1, true))
assert(received.pending == "", "report attachment sent input outside bracketed paste")
assert(s.job == job, "report attachment restarted the terminal agent")
assert(vim.fn.readfile(report)[1] == "Existing findings.")
sessions.delete(s)
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print("Terminal report tests passed (worktree storage, popup, bracketed paste, no submit key, same agent process).")
