-- Run from the repository root: nvim --headless -u NONE -l tests/terminal_exit.lua
-- An embedded child runs a real input loop, so terminal/insert modes are exercised.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local child = vim.fn.jobstart(
	{ vim.v.progpath, "--headless", "--embed", "-u", "NONE", "-i", "NONE", "-n" },
	{ rpc = true }
)
assert(child > 0)
local function lua(code, args)
	return vim.rpcrequest(child, "nvim_exec_lua", code, args or {})
end
local function input(keys)
	vim.rpcrequest(child, "nvim_input", keys)
end
local function wait(fn)
	assert(vim.wait(5000, fn, 10), "timed out")
end
local function mode()
	return vim.rpcrequest(child, "nvim_get_mode").mode
end

local ok, err = xpcall(function()
	lua(
		[[
		local root, state = ...
		vim.opt.rtp:prepend(root)
		require("aero").setup({
			state_file = state, animation = false, fullscreen_key = false,
			agents = { eof = {
				cmd = { "sh", "-c", "printf 'ready\\n'; cat; printf 'goodbye\\n'" },
				resume = { "sh", "-c", "printf 'ready\\n'; cat; printf 'goodbye\\n'" },
			} },
		})
		local code = vim.api.nvim_get_current_win()
		local s = require("aero.session").create(root, "eof")
		require("aero.panel").focus(s)
		_G.exit_test = { s = s, code = code, panel = require("aero.panel").win(), enters = 0 }
		vim.api.nvim_create_autocmd("TermEnter", { callback = function() _G.exit_test.enters = _G.exit_test.enters + 1 end })
	]],
		{ vim.fn.getcwd(), dir .. "/state.json" }
	)
	wait(function()
		return mode() == "t"
	end)
	wait(function()
		return lua(
			"return table.concat(vim.api.nvim_buf_get_lines(_G.exit_test.s.buf, 0, -1, false), '\\n'):find('ready', 1, true) ~= nil"
		)
	end)
	input("\004") -- Ctrl-D: EOF through the actual terminal input callback.
	wait(function()
		return lua("return _G.exit_test.s.exit_code ~= nil")
	end)
	assert(mode():sub(1, 1) == "n", "process exited but cursor remained trapped in terminal input mode")
	assert(lua("return vim.api.nvim_buf_is_valid(_G.exit_test.s.buf)"), "exit removed the scrollback buffer")
	assert(
		lua(
			"return table.concat(vim.api.nvim_buf_get_lines(_G.exit_test.s.buf, 0, -1, false), '\\n'):find('goodbye', 1, true) ~= nil"
		)
	)
	input("\023h") -- Ctrl-W h must navigate back to the code pane without a terminal escape.
	wait(function()
		return lua("return vim.api.nvim_get_current_win() == _G.exit_test.code")
	end)

	-- Entering the exited terminal again cannot trap input.
	lua("vim.api.nvim_set_current_win(_G.exit_test.panel)")
	local before = lua("return _G.exit_test.enters")
	input("i")
	wait(function()
		return lua("return _G.exit_test.enters") > before and mode():sub(1, 1) == "n"
	end)

	-- An agent exiting in the background must not interrupt editing in the code pane.
	lua([[
		vim.api.nvim_set_current_win(_G.exit_test.code)
		assert(require("aero.session").start(_G.exit_test.s, _G.exit_test.panel, true))
	]])
	input("i")
	wait(function()
		return mode() == "i"
	end)
	lua("vim.fn.chansend(_G.exit_test.s.job, '\004')")
	wait(function()
		return lua("return _G.exit_test.s.exit_code ~= nil")
	end)
	assert(mode() == "i", "background exit interrupted insert mode")
	assert(lua("return vim.api.nvim_get_current_win() == _G.exit_test.code"), "background exit stole focus")
end, debug.traceback)

vim.rpcnotify(child, "nvim_command", "qa!")
if vim.fn.jobwait({ child }, 1000)[1] == -1 then
	vim.fn.jobstop(child)
end
vim.fn.delete(dir, "rf")
assert(ok, err)
print("Terminal exit tests passed (Ctrl-D, normal-mode navigation, dead-terminal reentry, background editing).")
