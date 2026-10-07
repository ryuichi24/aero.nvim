-- Run: nvim --headless -u NONE -l tests/prompt_completion.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local completion = require("aero.acp.completion")
local buf = api.nvim_create_buf(false, true)
api.nvim_set_current_buf(buf)
vim.o.virtualedit = "onemore"
completion.setup(buf)
assert(vim.b[buf].completion == false and vim.b[buf].minicompletion_disable == true)
assert(vim.b[buf].coc_suggest_disable == 1)
local other = api.nvim_create_buf(false, true)
assert(vim.b[other].completion == nil, "completion was disabled outside the prompt")
local guard = require("aero.acp.completion_guard")
local original_cmp, original_blink = package.loaded["cmp"], package.loaded["blink.cmp"]
local get_clients, enable = vim.lsp.get_clients, vim.lsp.completion.enable
local disabled, aborted, hidden, lsp_disabled = false, false, false, false
package.loaded["cmp"] = {
	setup = { buffer = function(opts)
		assert(api.nvim_get_current_buf() == buf)
		disabled = opts.enabled == false
	end },
	abort = function() aborted = true end,
}
package.loaded["blink.cmp"] = { hide = function() hidden = true end }
vim.lsp.get_clients = function(opts) assert(opts.bufnr == buf); return { { id = 42 } } end
vim.lsp.completion.enable = function(value, client, buffer)
	lsp_disabled = value == false and client == 42 and buffer == buf
end
guard.apply(buf)
assert(disabled and aborted and hidden and lsp_disabled)
package.loaded["cmp"], package.loaded["blink.cmp"] = original_cmp, original_blink
vim.lsp.get_clients, vim.lsp.completion.enable = get_clients, enable
vim.keymap.set("i", "<C-n>", "overridden", { buffer = buf })
api.nvim_exec_autocmds("FileType", { buffer = buf })
assert(vim.wait(1000, function()
	return vim.fn.maparg("<C-n>", "i", false, true).desc == "Aero: navigate prompt suggestions"
end), "FileType completion mapping replaced Aero navigation")
local function suggestions(text)
	api.nvim_buf_set_lines(buf, 0, -1, false, { text })
	api.nvim_win_set_cursor(0, { 1, #text })
	return completion.candidates()
end
local start, items = suggestions("/")
assert(start == 1 and #items >= 6)
local found = {}
for _, item in ipairs(items) do found[item.word] = item.menu end
assert(found["/report"] and found["/export"] and found["/cancel"])
for _, width in ipairs({ 20, 30, 45 }) do
	local fitted = completion.fit(items, width)
	local longest, menu = 0, 0
	for i, item in ipairs(fitted) do
		longest = math.max(longest, vim.fn.strdisplaywidth(item.abbr))
		menu = math.max(menu, vim.fn.strdisplaywidth(item.menu))
		assert(item.word == items[i].word, "fitting changed the inserted command")
	end
	assert(longest + menu + 4 <= width, "full slash menu exceeds shared width budget")
end
start, items = suggestions("  /rep")
assert(start == 3 and #items == 1 and items[1].word == "/report")
start, items = suggestions("/exp")
assert(#items == 1 and items[1].word == "/export")
assert(suggestions("Discuss /rep") == nil)
assert(suggestions("/src/example") == nil)
assert(suggestions("/report details") == nil)
assert(vim.bo[buf].completeopt:find("noselect", 1, true))
local original_width = vim.o.pumwidth
local has_maxwidth = vim.fn.exists("+pummaxwidth") == 1
local original_maxwidth = has_maxwidth and vim.o.pummaxwidth
vim.cmd("botright 30vsplit")
api.nvim_exec_autocmds("InsertEnter", { buffer = buf })
assert(vim.o.pumwidth <= api.nvim_win_get_width(0) - 2)
if has_maxwidth then
	assert(vim.o.pummaxwidth > 0 and vim.o.pummaxwidth <= api.nvim_win_get_width(0) - 2)
end
api.nvim_exec_autocmds("InsertLeave", { buffer = buf })
assert(vim.o.pumwidth == original_width)
if has_maxwidth then assert(vim.o.pummaxwidth == original_maxwidth) end
print("prompt completion: ok")
vim.cmd.qa({ bang = true })
