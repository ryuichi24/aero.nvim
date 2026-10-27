-- Run: nvim --headless -u NONE -l tests/picker_completion.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local code = api.nvim_get_current_buf()
local disabled = {}
package.loaded.cmp = {
	setup = {
		buffer = function(opts)
			assert(opts.enabled == false)

			disabled[api.nvim_get_current_buf()] = true
		end,
	},
	abort = function() end,
}
local picker = require("aero.picker")
local selected
picker.open({
	title = "completion check",
	items = function()
		return { { key = "one" }, { key = "two" } }
	end,
	label = function(item)
		return item.key
	end,
	select = function(item)
		selected = item.key
	end,
})
local search = api.nvim_get_current_buf()

assert(disabled[search] and not disabled[code])
assert(vim.b[search].completion == false)
assert(vim.b[search].minicompletion_disable == true)
assert(vim.b[search].coc_suggest_disable == 1)

local function overwrite()
	for _, key in ipairs({ "<C-n>", "<C-p>", "<CR>" }) do
		vim.keymap.set("i", key, function()
			error("completion took over navigation")
		end, { buffer = search })
	end
end

local function key(name)
	vim.fn.maparg(name, "i", false, true).callback()
end

overwrite()
api.nvim_exec_autocmds("InsertEnter", { buffer = search })
key("<C-n>")
key("<C-p>")
overwrite()
api.nvim_exec_autocmds("LspAttach", { buffer = search, data = { client_id = 0 } })
vim.wait(20, function()
	return false
end)
key("<C-n>")
key("<CR>")

assert(selected == "two", "insert navigation did not select the second result")
assert(vim.b[code].completion == nil, "completion guard affected the code buffer")

print("picker completion: ok")
vim.cmd.qa({ bang = true })
