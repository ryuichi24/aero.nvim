-- Optional real-provider check: AERO_TEST_DRESSING=/path/to/dressing.nvim
-- nvim --headless -u NONE -c 'luafile tests/input_dressing.lua'
local provider = vim.env.AERO_TEST_DRESSING

if not provider then
	print("input dressing: skipped (set AERO_TEST_DRESSING)")
	vim.cmd("qa!")
	return
end

vim.opt.rtp:prepend(vim.fn.getcwd())
vim.opt.rtp:append(provider)
require("dressing").setup({ input = { start_mode = "insert" } })

local function fail(err)
	io.stderr:write(tostring(err) .. "\n")
	vim.cmd("cquit 1")
end

vim.cmd.startinsert()
vim.defer_fn(function()
	require("aero.input").input({ default = "hello.jpeg", select_length = 5 }, function(value)
		if value ~= "test.jpeg" then
			return fail("expected test.jpeg; got " .. tostring(value))
		end

		print("input dressing: OK")
		vim.cmd("qa!")
	end)
	vim.defer_fn(function()
		if vim.fn.mode() ~= "s" then
			return fail("filename stem was not selected")
		end

		if vim.api.nvim_win_get_cursor(0)[2] ~= 4 then
			return fail("selection excluded the final stem character")
		end

		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("test<Esc><CR>", true, false, true), "mt", false)
	end, 100)
end, 20)
vim.defer_fn(function()
	fail("input dressing timed out")
end, 3000)
