-- Run from the repository root: nvim --headless -u NONE -l tests/quote_terminal.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local report = dir .. "/pastes.json"
local file = dir .. "/code.lua"
vim.fn.writefile({ "print('quoted code')" }, file)
local aero = require("aero")
aero.setup({
	state_file = dir .. "/state.json", animation = false, start_insert = false,
	agents = { fixture = { cmd = { "python3", root .. "/tests/fixtures/quote_terminal.py", report } } },
})
vim.cmd.edit(vim.fn.fnameescape(file))
vim.bo.filetype = "lua"
local code, code_buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local sessions = require("aero.session")
local s = sessions.create(dir, "fixture")
local panel = require("aero.panel")
assert(panel.show(s))
assert(vim.wait(5000, function()
	return vim.fn.filereadable(report) == 1
end, 10))
local function received(count)
	local data
	assert(vim.wait(5000, function()
		local ok, value = pcall(vim.json.decode, table.concat(vim.fn.readfile(report), "\n"))
		if ok and #value.pastes == count then
			data = value
			return true
		end
	end, 10), "terminal did not receive the bracketed quote")
	assert(data.pending == "", "quote sent input outside bracketed paste")
	return data.pastes[count]
end
local function quote_line(win, line)
	api.nvim_set_current_win(win)
	api.nvim_win_set_cursor(win, { line, 0 })
	vim.cmd.normal({ args = { "V" }, bang = true })
	aero.quote()
end
local job = s.job
quote_line(code, 1)
assert(received(1):find("```lua\nprint('quoted code')\n```", 1, true))
assert(api.nvim_win_get_buf(code) == code_buf, "quoting replaced the code buffer")
assert(s.job == job, "quoting restarted the terminal agent")
local line
assert(vim.wait(5000, function()
	for i, text in ipairs(api.nvim_buf_get_lines(s.buf, 0, -1, false)) do
		if text == "terminal log text" then
			line = i
			return true
		end
	end
end, 10))
quote_line(panel.win(), line)
local quoted_log = received(2)
assert(quoted_log:find("Quoted from agent log: " .. s.name, 1, true))
assert(quoted_log:find("\nterminal log text\n", 1, true))
assert(s.job == job, "quoting the agent's log restarted it")
sessions.delete(s)
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print("Terminal quote tests passed (code/log selections, bracketed paste, no submit key, same process).")
