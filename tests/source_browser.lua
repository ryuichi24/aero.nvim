vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = vim.fn.resolve(root)
require("aero").setup({ state_file = root .. "/state.json", companion = { auto_start = false } })
vim.t.aero_worktree = root
local reader = require("aero.reader")
local navigation = require("aero.navigation")
local source_win = navigation.code_window()
local source = api.nvim_win_get_buf(source_win)
reader.select("reports")
local report = api.nvim_get_current_buf()
api.nvim_buf_set_lines(report, 0, -1, false, { "report draft" })
local opened
package.loaded.oil = {
	open = function(path)
		opened = path
		assert(vim.w.aero_reader_kind == "source")
		assert(api.nvim_get_current_buf() == source)
	end,
}
navigation.browse_worktree(root)
assert(opened == root, "Oil must receive the checkout root, not the remembered report")
reader.select("reports")
assert(api.nvim_get_current_buf() == report)
assert(api.nvim_buf_get_lines(report, 0, -1, false)[1] == "report draft")
package.loaded.oil = nil
package.preload.oil = function()
	error("Oil unavailable")
end
navigation.browse_worktree(root)
assert(vim.w.aero_reader_kind == "source")
assert(api.nvim_buf_get_name(0) == root)
reader.select("reports")
assert(api.nvim_get_current_buf() == report)
vim.fn.delete(root, "rf")
print("source browser: ok")
vim.cmd("qa!")
