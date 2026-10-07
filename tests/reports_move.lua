-- Run: nvim --headless -u NONE -l tests/reports_move.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
local target = dir .. "/other"
vim.fn.mkdir(target, "p")
require("aero").setup({ state_file = dir .. "/state.json", animation = false, reports = { directory = "worktree" } })
local git = require("aero.git")
git.list = function()
	return { { path = dir, branch = "main" }, { path = target, branch = "other" } }
end
git.remote_status = function(_, cb)
	cb({})
end
local ws = require("aero.store").add_workspace(dir)
local reports = require("aero.reports")
local report = assert(reports.create_file(dir, ws, "findings", "saved findings\n"))
local buf = vim.fn.bufadd(report.path)
vim.fn.bufload(buf)
api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved findings" })
local dashboard = require("aero.dashboard")
dashboard.open()
local win, sidebar = api.nvim_get_current_win(), api.nvim_get_current_buf()
-- Expand the source worktree so its report action is available.
for i, line in ipairs(api.nvim_buf_get_lines(sidebar, 0, -1, false)) do
	if line:find("main", 1, true) then
		api.nvim_win_set_cursor(win, { i, 0 })
		vim.fn.maparg("l", "n", false, true).callback()
		break
	end
end
local function move(choice)
	for i, line in ipairs(api.nvim_buf_get_lines(sidebar, 0, -1, false)) do
		if line:find("findings.md", 1, true) then
			api.nvim_win_set_cursor(win, { i, 0 })
			require("aero.picker").open = function(opts)
				local items = opts.items()
				assert(#items == 1 and items[1].wt.path == target)
				assert(opts.label(items[1]):find("other", 1, true))
				assert(opts.group(items[1]):find(ws.name, 1, true))
				if choice then
					opts.select(items[1])
				end
			end
			vim.fn.maparg("m", "n", false, true).callback()
			return
		end
	end
	error("report missing from dashboard")
end
move(false)
assert(vim.uv.fs_stat(report.path), "cancelled move changed source")
local collision = assert(reports.create_file(target, ws, report.name, "existing\n"))
vim.notify = function() end
move(true)
assert(vim.fn.readfile(collision.path)[1] == "existing")
assert(vim.uv.fs_stat(report.path), "collision removed source")
assert(vim.uv.fs_unlink(collision.path))
local target_buf = vim.fn.bufadd(collision.path)
assert(not reports.move(report, target, ws), "destination buffer collision accepted")
api.nvim_buf_delete(target_buf, { force = true })
local unlink = vim.uv.fs_unlink
vim.uv.fs_unlink = function(path)
	if path == report.path then
		return nil, "injected failure"
	end
	return unlink(path)
end
assert(not reports.move(report, target, ws))
vim.uv.fs_unlink = unlink
assert(vim.uv.fs_stat(report.path) and not vim.uv.fs_stat(collision.path), "failed move did not roll back")
move(true)
assert(not vim.uv.fs_stat(report.path))
assert(vim.fn.readfile(collision.path)[1] == "saved findings")
assert(api.nvim_buf_get_name(buf) == collision.path)
assert(vim.bo[buf].modified and api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unsaved findings")
assert(#reports.list(dir, ws) == 0 and #reports.list(target, ws) == 1)
-- Cross-workspace moves must resolve storage against the destination workspace.
local foreign_root = dir .. "/foreign"
local foreign_target = foreign_root .. "/worktree"
vim.fn.mkdir(foreign_target, "p")
local foreign_ws = require("aero.store").add_workspace(foreign_root)
require("aero.store").set_expanded(foreign_root, false)
git.list = function(root)
	if root == foreign_root then
		return { { path = foreign_target, branch = "foreign-branch" } }
	end
	return { { path = dir, branch = "main" }, { path = target, branch = "other" } }
end
require("aero.config").options.reports.directory = dir .. "/cross-workspace-storage"
local cross = assert(reports.create_file(target, ws, "cross-workspace", "foreign findings"))
dashboard.render()
local selected = false
require("aero.picker").open = function(opts)
	local items = opts.items()
	assert(#items == 2)
	for _, choice in ipairs(items) do
		if choice.wt.path == foreign_target then
			assert(choice.ws.root == foreign_ws.root)
			assert(opts.group(choice):find(foreign_ws.name, 1, true))
			assert(opts.search(choice):find("foreign-branch", 1, true))
			opts.select(choice)
			selected = true
			return
		end
	end
	error("foreign worktree missing from picker")
end
for i, line in ipairs(api.nvim_buf_get_lines(sidebar, 0, -1, false)) do
	if line:find("cross-workspace.md", 1, true) then
		api.nvim_win_set_cursor(win, { i, 0 })
		vim.fn.maparg("m", "n", false, true).callback()
		break
	end
end
assert(selected, "cross-workspace action not invoked")
local foreign_path = reports.directory(foreign_target, foreign_ws) .. "/cross-workspace.md"
assert(not vim.uv.fs_stat(cross.path) and vim.fn.readfile(foreign_path)[1] == "foreign findings")
assert(not vim.uv.fs_stat(reports.directory(foreign_target, ws) .. "/cross-workspace.md"))
assert(require("aero.store").find_workspace(foreign_root).expanded)
-- Default and custom roots use the destination worktree's isolated directory.
for _, setting in ipairs({ "data", dir .. "/custom", ".notes/reports" }) do
	require("aero.config").options.reports.directory = setting
	local source = assert(reports.create_file(dir, ws, "storage-check", "content"))
	local moved = assert(reports.move(source, target, ws))
	assert(moved.path == reports.directory(target, ws) .. "/storage-check.md")
	assert(not vim.uv.fs_stat(source.path) and vim.fn.readfile(moved.path)[1] == "content")
	vim.fn.delete(vim.fs.dirname(source.path), "rf")
	vim.fn.delete(vim.fs.dirname(moved.path), "rf")
end
vim.fn.delete(dir, "rf")
print("Report move tests passed (dashboard, cancellation, collisions, rollback, buffers, storage).")
vim.cmd.qa({ bang = true })
