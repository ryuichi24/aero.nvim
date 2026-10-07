-- Run: nvim --headless -u NONE -c 'luafile tests/prompt_paths_inline.lua'
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root .. "/src/nested", "p")
vim.fn.writefile({ "hello" }, root .. "/src/nested/example.lua")
vim.fn.writefile({ "hello" }, root .. "/space name.txt")
vim.o.columns = 120
vim.cmd("botright 35vnew")
local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
require("aero.acp.completion").setup(buf, root)
local path_menu = require("aero.acp.path_menu")
vim.keymap.set("i", "<CR>", function() path_menu.accept(buf) end, { buffer = buf })
local function check(fn)
	local ok, err = pcall(fn)
	if not ok then
		vim.fn.delete(root, "rf")
		print(err)
		vim.cmd("cq")
	end
end
local function menu()
	assert(api.nvim_get_current_buf() == buf, "path completion moved focus away from the draft")
	assert(path_menu.visible(buf), "inline menu is missing")
	for _, popup in ipairs(api.nvim_list_wins()) do
		local config = api.nvim_win_get_config(popup)
		if config.relative == "editor" then
			local pos = api.nvim_win_get_position(win)
			assert(config.col >= pos[2] and config.col + config.width <= pos[2] + api.nvim_win_get_width(win))
			local cursor = api.nvim_win_get_cursor(win)
			local first = vim.fn.screenpos(win, cursor[1], 1).row - 1
			local last = vim.fn.screenpos(win, cursor[1], cursor[2] + 1).row - 1
			assert(config.row > last or config.row + config.height <= first, "menu covers the wrapped query")
			return api.nvim_buf_get_lines(api.nvim_win_get_buf(popup), 0, -1, false), api.nvim_win_get_cursor(popup)[1]
		end
	end
	error("path popup not found")
end
-- Delay scanning to ensure queries typed during loading are retained.
local paths = require("aero.acp.paths")
local original = paths.items
paths.items = function(dir, callback)
	vim.defer_fn(function() original(dir, callback) end, 150)
end
local prefix = "Review " .. string.rep("long draft text ", 4)
api.nvim_input("i" .. prefix .. "@")
vim.defer_fn(function() api.nvim_input("sne") end, 60)
vim.defer_fn(function() check(function()
	local items = menu()
	assert(items[1]:find("src/nested", 1, true) == 1, "async results ignored the current query")
	assert(#items > 1)
	vim.fn.maparg("<C-n>", "i", false, true).callback()
	local _, selected = menu()
	assert(selected == 2, "Ctrl-n did not select the next path")
	vim.fn.maparg("<C-p>", "i", false, true).callback()
	_, selected = menu()
	assert(selected == 1, "Ctrl-p did not select the previous path")
	assert(api.nvim_get_current_line() == prefix .. "@sne", "Ctrl-n/p altered the typed query")
	assert(vim.fn.pumvisible() == 0, "native completion overlaps the path menu")
	vim.fn.complete(api.nvim_win_get_cursor(0)[2] + 1, { { word = "unrelated-lsp-result", equal = 1 } })
	assert(vim.wait(1000, function() return vim.fn.pumvisible() == 0 end), "competing native menu was not dismissed")
	assert(path_menu.visible(buf), "dismissing native completion closed Aero's menu")
	api.nvim_input("<BS><BS><BS>space")
	vim.defer_fn(function() check(function()
		local filtered = menu()
		assert(#filtered == 1 and filtered[1]:find("space name.txt", 1, true) == 1, "live fuzzy filtering failed")
		api.nvim_input("<Tab>")
		vim.defer_fn(function() check(function()
			assert(api.nvim_get_current_line() == prefix .. "@space", "navigation changed the query")
			api.nvim_input("<CR>")
			vim.defer_fn(function() check(function()
				assert(api.nvim_get_current_line() == prefix .. '@"space name.txt" ')
				assert(api.nvim_get_current_buf() == buf)
				-- At the bottom of a short panel, place suggestions above the wrapped line.
				vim.cmd("belowright 5split")
				win = api.nvim_get_current_win()
				vim.wo[win].scrolloff = 0
				local text = string.rep("q", 70) .. " @space"
				api.nvim_buf_set_lines(buf, 0, -1, false, { "", "", text })
				api.nvim_win_set_cursor(win, { 3, #text })
				vim.cmd("redraw")
				path_menu.show(buf, #text - 5, paths.candidates({ { key = "space name.txt" } }, "space"))
				menu()
				path_menu.close()
				vim.fn.delete(root, "rf")
				print("inline prompt paths: ok")
				vim.cmd("qa!")
			end) end, 100)
		end) end, 100)
	end) end, 100)
end) end, 500)
