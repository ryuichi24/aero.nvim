-- Run: nvim --headless -u NONE -l tests/rename.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({ state_file = dir .. "/state.json", animation = false, reports = { directory = "worktree" } })
local store = require("aero.store")
local sessions = require("aero.session")
local reports = require("aero.reports")
require("aero.git").list = function()
	return { { path = dir, branch = "main" } }
end
local ws = store.add_workspace(dir)
local s = sessions.create(dir, "opencode")
local original_key = s.key
require("aero.history").save(s, function()
	return { marker = "saved history" }
end)
require("aero.history").flush(s)
local dashboard = require("aero.dashboard")
dashboard.open()
local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local function rename(label, name)
	for i, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:sub(-#label) == label then
			api.nvim_win_set_cursor(win, { i, 0 })
			vim.ui.input = function(opts, cb)
				assert(opts.default == label)
				cb(name)
			end
			api.nvim_buf_call(buf, function()
				vim.fn.maparg("N", "n", false, true).callback()
			end)
			return
		end
	end
	error("missing sidebar item: " .. label)
end
rename(s.name, "renamed agent")
assert(s.key == original_key and s.name == "renamed agent")
assert(sessions.list(dir)[1] == s)
assert(require("aero.history").load(s).marker == "saved history")
store.load()
assert(store.find_session(dir, s.name).key == original_key)
local second = sessions.create(dir, "opencode")
assert(second.key ~= original_key)
local old_notify = vim.notify
vim.notify = function() end
rename(s.name, second.name)
assert(s.name == "renamed agent", "duplicate session name accepted")
rename(s.name, nil)
assert(s.name == "renamed agent")
vim.ui.input = function(_, cb) cb("original") end
local report
reports.create(dir, ws, function(value) report = value end)
local report_buf = vim.fn.bufadd(report.path)
vim.fn.bufload(report_buf)
api.nvim_buf_set_lines(report_buf, 0, -1, false, { "unsaved content" })
rename("original.md", "renamed report")
local path = reports.directory(dir, ws) .. "/renamed report.md"
assert(not vim.uv.fs_stat(report.path) and vim.uv.fs_stat(path))
assert(api.nvim_buf_get_name(report_buf) == path)
assert(vim.bo[report_buf].modified)
assert(api.nvim_buf_get_lines(report_buf, 0, -1, false)[1] == "unsaved content")
rename("renamed report.md", "../invalid")
assert(vim.uv.fs_stat(path))
rename("renamed report.md", nil)
assert(vim.uv.fs_stat(path))
assert(api.nvim_get_current_win() == win)
-- Reconstruct runtime as a new Neovim instance would, retaining history identity.
package.loaded["aero.session"] = nil
local restored = require("aero.session").list(dir)[1]
assert(restored.name == s.name and restored.key == original_key)
assert(require("aero.history").load(restored).marker == "saved history")
vim.notify = old_notify
vim.fn.delete(dir, "rf")
print("Rename tests passed (sidebar, persistence, history, collisions, cancellation, report buffers).")
vim.cmd.qa({ bang = true })
