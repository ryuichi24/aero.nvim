-- Run: nvim --headless -u NONE -l tests/input.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local config = require("aero.config")
local input = require("aero.input")

local clipboard = { ["+"] = { { "previous clipboard" }, "v" }, ["*"] = { { "previous selection" }, "v" } }
local clipboard_writes = 0
vim.g.clipboard = {
	name = "input-test",
	copy = {},
	paste = {},
	cache_enabled = 0,
}
local provider = vim.g.clipboard

for _, name in ipairs({ "+", "*" }) do
	provider.copy[name] = function(lines, regtype)
		clipboard_writes = clipboard_writes + 1
		clipboard[name] = { lines, regtype }
	end
	provider.paste[name] = function()
		return clipboard[name]
	end
end

vim.g.clipboard = provider
vim.opt.clipboard = { "unnamed", "unnamedplus" }

local function keys(text)
	api.nvim_feedkeys(api.nvim_replace_termcodes(text, true, false, true), "mtx", false)
end

local function save_registers()
	local registers = {}

	for _, name in ipairs({ "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", '"' }) do
		vim.fn.setreg(name, "previous " .. name)
	end

	for _, name in ipairs({ '"', "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "*" }) do
		registers[name] = vim.fn.getreginfo(name)
	end

	return registers
end

local function check_registers(registers)
	for name, info in pairs(registers) do
		assert(vim.deep_equal(vim.fn.getreginfo(name), info), "replacement changed register " .. name)
	end
end

for _, case in ipairs({
	{ ft = "DressingInput", clipboard = "" },
	{ ft = "snacks_input", clipboard = "" },
	{ ft = "DressingInput", clipboard = "unnamed" },
	{ ft = "snacks_input", clipboard = "unnamedplus" },
	{ ft = "DressingInput", clipboard = "unnamed,unnamedplus" },
	{ ft = "snacks_input", clipboard = "unnamed,unnamedplus" },
}) do
	local ft = case.ft
	vim.o.clipboard = case.clipboard
	local buf, win, result
	vim.ui.input = function(opts, callback)
		buf = api.nvim_create_buf(false, true)
		win = api.nvim_open_win(buf, true, { relative = "editor", row = 1, col = 1, width = 30, height = 1 })

		-- Dressing sets filetype before inserting the default.
		vim.bo[buf].filetype = ft
		api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default })
		vim.keymap.set("n", "<CR>", function()
			callback(api.nvim_buf_get_lines(buf, 0, 1, false)[1])
		end, { buffer = buf })
	end
	input.input({ prompt = "Name", default = "opencode-acp" }, function(value)
		result = value
	end)
	vim.wait(20, function()
		return false
	end)
	keys("") -- process queued Select-mode transition

	assert(vim.fn.mode() == "S", ft .. " did not select the entire input line")

	keys("<CR>")

	assert(result == "opencode-acp", ft .. " did not keep the default on Enter")

	api.nvim_win_close(win, true)
	api.nvim_buf_delete(buf, { force = true })
	input.input({ prompt = "Name", default = "opencode-acp" }, function(value)
		result = value
	end)
	vim.wait(20, function()
		return false
	end)
	keys("replacement<Esc><CR>")

	assert(result == "replacement", ft .. " did not replace the default on typing")

	api.nvim_win_close(win, true)
	api.nvim_buf_delete(buf, { force = true })

	for _, selection in ipairs({ "inclusive", "exclusive" }) do
		for _, virtualedit in ipairs({ "", "onemore", "all" }) do
			for _, name in ipairs({ "x", "opencode-acp", "session-é", "session-界" }) do
				local previous = save_registers()
				vim.o.selection = selection
				vim.o.virtualedit = virtualedit
				input.input({ prompt = "Name", default = name }, function(value)
					result = value
				end)
				vim.wait(20, function()
					return false
				end)
				keys("")

				assert(vim.fn.mode() == "S", "default name is not selected linewise")

				local replacement = name == "session-界" and "新しい" or "new"
				clipboard_writes = 0
				keys(replacement .. "<Esc><CR>")

				assert(result == replacement, ft .. " left part of " .. name .. " unselected")
				assert(clipboard_writes == 0, "replacement wrote to clipboard before restoring it")

				check_registers(previous)

				assert(api.nvim_buf_line_count(buf) == 1, "replacement added an extra line")

				api.nvim_win_close(win, true)
				api.nvim_buf_delete(buf, { force = true })
			end
		end
	end

	vim.o.selection = "inclusive"
	vim.o.virtualedit = ""

	for _, selection in ipairs({ "inclusive", "exclusive", "old" }) do
		vim.o.selection = selection

		for _, name in ipairs({ "note.md", "x.txt", "session-é.lua", "session-界.tar.gz" }) do
			local previous = save_registers()
			local stem = assert(name:match("^(.+)%.[^.]+$"))
			input.input({ prompt = "Rename", default = name, select_length = #stem }, function(value)
				result = value
			end)
			vim.wait(20, function()
				return false
			end)
			keys("")

			assert(vim.fn.mode() == "s", "filename stem is not selected characterwise")

			clipboard_writes = 0
			keys("new<Esc><CR>")

			assert(result == "new" .. name:sub(#stem + 1), ft .. " did not preserve extension: " .. tostring(result))

			check_registers(previous)

			assert(clipboard_writes == 0, "stem replacement wrote to clipboard")

			assert(vim.o.selection == selection, "filename selection did not restore user's selection option")

			api.nvim_win_close(win, true)
			api.nvim_buf_delete(buf, { force = true })
		end
	end

	vim.o.selection = "inclusive"
end

local received
config.options.input.adapter = function(opts, callback)
	received = opts
	callback("custom")
end
local result
input.input({ default = "name" }, function(value)
	result = value
end)

assert(received.select_default and received.default == "name" and result == "custom")

config.options.input.adapter = "vim_ui"
vim.ui.input = function(_, callback)
	callback(nil)
end
input.input({ default = "name" }, function(value)
	result = value
end)

assert(result == nil)

-- Real input arrives through the event loop, unlike feedkeys(..., "x").
local child = vim.fn.jobstart({ vim.v.progpath, "--embed", "--headless", "-u", "NONE", "-i", "NONE" }, { rpc = true })
local function exec(code)
	return vim.rpcrequest(child, "nvim_exec_lua", code, {})
end

exec([[
	vim.opt.rtp:prepend(vim.fn.getcwd())
	vim.fn.setreg('"', 'keep this')
	vim.ui.input = function(opts, callback)
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_open_win(buf, true, { relative = 'editor', row = 1, col = 1, width = 30, height = 1 })
		vim.bo[buf].filetype = 'DressingInput'
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { opts.default })
	end
	require('aero.input').input({ default = 'default session' }, function() end)
]])

assert(
	vim.wait(1000, function()
		return exec("return vim.fn.mode()") == "S"
	end),
	"child did not select default"
)

vim.rpcrequest(child, "nvim_input", "new")

assert(
	vim.wait(1000, function()
		return exec("return vim.api.nvim_get_current_line()") == "new"
	end),
	"child did not replace default"
)

local register = exec([[return vim.fn.getreg('"')]])
vim.fn.jobstop(child)

assert(register == "keep this", "event-loop replacement changed register: " .. register)

print("Input adapter tests passed.")
