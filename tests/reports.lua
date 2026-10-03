-- Run from the repository root: nvim --headless -u NONE -l tests/reports.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/main", "p")
vim.fn.mkdir(dir .. "/feature", "p")
dir = vim.fn.resolve(dir)
local main, feature = dir .. "/main", dir .. "/feature"
local git = require("aero.git")
git.list = function()
	return { { path = main, branch = "main" }, { path = feature, branch = "feature" } }
end
git.main_root = function()
	return main
end
local aero = require("aero")
local opts = {
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	worktree_tabs = false,
	agents = { fixture = { type = "acp", cmd = { "python3", root .. "/tests/fixtures/acp.py", "save" } } },
}
aero.setup(vim.deepcopy(opts))
vim.cmd.runtime("plugin/aero.lua")
local reports, config = require("aero.reports"), require("aero.config")
local store, sessions, panel = require("aero.store"), require("aero.session"), require("aero.panel")
local ws = store.add_workspace(main)
local expected = vim.fn.stdpath("data") .. "/Aero/workspaces/"
assert(reports.directory(main, ws):find(expected, 1, true) == 1)
assert(reports.directory(main, ws):match("/reports$"))
assert(reports.directory(main, ws) ~= reports.directory(feature, ws))
assert(
	reports.directory(main, ws) ~= reports.directory(main, { root = dir .. "/other/main" }),
	"same-named workspaces collided"
)
assert(#reports.list(main, ws) == 0, "listing created or discovered unexpected reports")

-- Custom roots preserve workspace/worktree isolation; relative and function paths are exact.
config.options.reports.directory = dir .. "/report storage"
local main_dir = reports.directory(main, ws)
local feature_dir = reports.directory(feature, ws)
assert(main_dir ~= feature_dir and main_dir:find(dir .. "/report storage/", 1, true) == 1)
config.options.reports.directory = "worktree"
assert(reports.directory(feature, ws) == feature .. "/.aero/reports")
config.options.reports.directory = ".notes/reports"
assert(reports.directory(feature, ws) == feature .. "/.notes/reports")
config.options.reports.directory = function(worktree, workspace)
	assert(worktree == feature and workspace == main)
	return "reports"
end
assert(reports.directory(feature, ws) == feature .. "/reports")
config.options.reports.directory = dir .. "/report storage"

local old_input, old_notify = vim.ui.input, vim.notify
local warnings = {}
vim.notify = function(message)
	table.insert(warnings, message)
end
local function create(path, name)
	local result
	vim.ui.input = function(_, callback)
		callback(name)
	end
	reports.create(path, ws, function(report)
		result = report
	end)
	return result
end
local first_report = assert(create(main, "design review"))
assert(first_report.path == main_dir .. "/design review.md")
assert(vim.uv.fs_stat(first_report.path).size == 0, "new report was not empty")
vim.fn.writefile({ "Keep existing findings." }, first_report.path)
assert(not create(main, "design review.md"))
assert(vim.fn.readfile(first_report.path)[1] == "Keep existing findings.", "duplicate report was overwritten")
assert(not create(main, "../outside") and not create(main, nil))
assert(not vim.uv.fs_stat(vim.fs.dirname(main_dir) .. "/outside.md"))
assert(#warnings >= 2)
local other_report = assert(create(feature, "design review"))
assert(other_report.path ~= first_report.path and #reports.list(feature, ws) == 1)
vim.fn.mkdir(main_dir .. "/folder.md", "p")
vim.fn.writefile({ "not a report" }, main_dir .. "/notes.txt")
assert(#reports.list(main, ws) == 1, "non-Markdown files or directories appeared in report list")

local s = sessions.create(main, "fixture")
local other = sessions.create(feature, "fixture")
assert(panel.show(s))
assert(vim.wait(5000, function()
	return s.chat.state == "ready"
end, 10))
vim.t.aero_worktree = main
local function draft(target)
	return table.concat(api.nvim_buf_get_lines(target.chat:get_prompt_buf(), 0, -1, false), "\n")
end
local function picker()
	assert(
		vim.b.aero_report_picker,
		"report command did not open a floating menu: "
			.. vim.inspect({ mode = vim.fn.mode(), lines = api.nvim_buf_get_lines(0, 0, -1, false) })
	)
	assert(api.nvim_win_get_config(0).relative == "editor")
	local lines = api.nvim_buf_get_lines(0, 0, -1, false)
	assert(lines[#lines] == "  New +", "New + was not last")
	return lines
end
local function choose(line)
	api.nvim_win_set_cursor(0, { line, 0 })
	vim.fn.maparg("<CR>", "n", false, true).callback()
end

api.nvim_buf_set_lines(s.chat:get_prompt_buf(), 0, -1, false, { "Investigate the issue." })
api.nvim_set_current_win(panel.win())
vim.cmd("Aero report")
assert(#picker() == 2)
choose(1)
assert(draft(s):find("Investigate the issue.\n\nReport file:", 1, true))
assert(draft(s):find(vim.json.encode(first_report.path), 1, true))
assert(draft(s):find("write or update", 1, true))
assert(#s.chat.blocks == 0 and #s.chat.queue == 0, "report was submitted automatically")
local before = draft(s)
vim.cmd("Aero report")
picker()
vim.fn.maparg("<Esc>", "n", false, true).callback()
assert(draft(s) == before, "cancel changed existing draft")

-- setup customizes the entire attachment text, preserving literal percent characters.
local custom_opts = vim.deepcopy(opts)
custom_opts.reports = { directory = dir .. "/report storage", prompt = "Review 100%: {path}\nUpdate {path}." }
aero.setup(custom_opts)
api.nvim_buf_set_lines(s.chat:get_prompt_buf(), 0, -1, false, { "Existing draft." })
reports.attach(s, first_report.path)
local quoted_path = vim.json.encode(first_report.path)
assert(draft(s) == "Existing draft.\n\nReview 100%: " .. quoted_path .. "\nUpdate " .. quoted_path .. ".\n")
assert(#s.chat.blocks == 0 and #s.chat.queue == 0, "custom report prompt was submitted automatically")
config.options.reports.prompt = config.defaults.reports.prompt

-- New + names, creates, and attaches a genuinely empty file.
vim.ui.input = function(_, callback)
	callback("investigation")
end
vim.cmd("Aero report")
choose(#picker())
assert(vim.uv.fs_stat(main_dir .. "/investigation.md").size == 0)
assert(draft(s):find(main_dir .. "/investigation.md", 1, true))
assert(#reports.list(main, ws) == 2)

-- /report is local even during an active turn; Enter keeps other drafts multiline.
s.chat:compose()
vim.cmd.stopinsert()
api.nvim_buf_set_lines(s.chat.prompt_buf, 0, -1, false, { "/report" })
s.chat.busy = true
s.chat:send_prompt_buf()
picker()
choose(1)
s.chat.busy = false
assert(#s.chat.blocks == 0 and #s.chat.queue == 0)
api.nvim_buf_set_lines(s.chat.prompt_buf, 0, -1, false, { "" })
api.nvim_feedkeys(api.nvim_replace_termcodes("i/report<CR>", true, false, true), "xt", false)
picker()
choose(1)
assert(#s.chat.blocks == 0, "Enter sent /report to the agent")
api.nvim_buf_set_lines(s.chat.prompt_buf, 0, -1, false, { "" })
api.nvim_feedkeys(api.nvim_replace_termcodes("iordinary<CR>draft<Esc>", true, false, true), "xt", false)
assert(draft(s) == "ordinary\ndraft", "Enter no longer inserts ordinary draft newlines")
api.nvim_buf_set_lines(s.chat.prompt_buf, 0, -1, false, { "/rep" })
vim.wo.virtualedit = "onemore"
api.nvim_win_set_cursor(0, { 1, 4 })
local complete = require("aero.acp").omnifunc(0, "/rep")
assert(#complete == 1 and complete[1].word == "/report")

-- Sidebar Reports sections open Markdown files in the code pane and target their own worktree.
aero.open()
local dashboard, dw = api.nvim_get_current_buf(), api.nvim_get_current_win()
local function row(text)
	for i, line in ipairs(api.nvim_buf_get_lines(dashboard, 0, -1, false)) do
		if line == text then
			return i
		end
	end
	error("missing dashboard row: " .. text)
end
local function action(line, key)
	api.nvim_set_current_win(dw)
	api.nvim_win_set_cursor(dw, { line, 0 })
	vim.fn.maparg(key, "n", false, true).callback()
end
local report_row = row("       design review.md")
action(report_row, "h")
assert(api.nvim_get_current_line():find("Reports", 1, true))
vim.fn.maparg("h", "n", false, true).callback()
assert(not table.concat(api.nvim_buf_get_lines(dashboard, 0, -1, false), "\n"):find("investigation.md", 1, true))
vim.fn.maparg("l", "n", false, true).callback()
action(row("       investigation.md"), "<CR>")
assert(api.nvim_buf_get_name(0) == main_dir .. "/investigation.md")
assert(api.nvim_get_current_win() ~= panel.win(), "report opened in agent panel")
assert(vim.t.aero_worktree == main)

aero.open()
dw = api.nvim_get_current_win()
local feature_row = row("   ▾ feature")
api.nvim_win_set_cursor(dw, { feature_row, 0 })
vim.cmd("Aero report")
local choices = picker()
assert(#choices == 2, "worktree picker leaked another worktree's reports")
choose(1)
assert(other.chat and draft(other):find(other_report.path, 1, true))
assert(vim.wait(5000, function()
	return other.chat.state == "ready"
end, 10))
assert(#other.chat.blocks == 0)

-- A cancelled naming prompt creates nothing; New + in the sidebar opens the new report.
aero.open()
dw = api.nvim_get_current_win()
vim.ui.input = function(_, callback)
	callback(nil)
end
action(row("       New +"), "<CR>")
assert(#reports.list(main, ws) == 2)
vim.ui.input = function(_, callback)
	callback("sidebar-note")
end
action(row("       New +"), "<CR>")
assert(api.nvim_buf_get_name(0) == main_dir .. "/sidebar-note.md")
assert(vim.uv.fs_stat(main_dir .. "/sidebar-note.md").size == 0)

-- d confirms before deleting only the selected report and refreshing the sidebar.
aero.open()
dw = api.nvim_get_current_win()
local old_confirm = vim.fn.confirm
vim.fn.confirm = function(prompt, choices, default)
	assert(prompt == "Delete report sidebar-note.md?")
	assert(choices == "&Yes\n&No" and default == 2)
	return 2
end
action(row("       sidebar-note.md"), "d")
assert(vim.uv.fs_stat(main_dir .. "/sidebar-note.md"), "cancelled deletion removed the report")
assert(row("       sidebar-note.md"))
vim.fn.confirm = function()
	return 1
end
action(row("       sidebar-note.md"), "d")
vim.fn.confirm = old_confirm
assert(not vim.uv.fs_stat(main_dir .. "/sidebar-note.md"))
assert(#reports.list(main, ws) == 2)
assert(vim.uv.fs_stat(other_report.path), "deleted another worktree's report")
assert(not table.concat(api.nvim_buf_get_lines(dashboard, 0, -1, false), "\n"):find("sidebar-note.md", 1, true))
assert(api.nvim_get_current_win() == dw, "deletion moved focus away from sidebar")

-- The same key on a session deletes its registration, leaving reports untouched.
local disposable = sessions.create(main, "fixture")
require("aero.dashboard").render()
local session_line
for i, line in ipairs(api.nvim_buf_get_lines(dashboard, 0, -1, false)) do
	if line:find(" " .. disposable.name, 1, true) then
		session_line = i
	end
end
vim.fn.confirm = function(prompt, choices, default)
	assert(prompt == "Delete session " .. disposable.name .. "?")
	assert(choices == "&Yes\n&No" and default == 2)
	return 2
end
action(assert(session_line, "missing disposable session row"), "d")
assert(vim.tbl_contains(sessions.list(main), disposable), "cancelled deletion removed the session")
vim.fn.confirm = function()
	return 1
end
action(session_line, "d")
vim.fn.confirm = old_confirm
assert(not vim.tbl_contains(sessions.list(main), disposable), "d did not delete selected session")
assert(vim.uv.fs_stat(first_report.path) and vim.uv.fs_stat(main_dir .. "/investigation.md"))
assert(#reports.list(main, ws) == 2, "session deletion changed reports")

vim.ui.input, vim.notify = old_input, old_notify
sessions.delete(other)
sessions.delete(s)
require("aero.buffers").flush()
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print(
	"Report tests passed (storage, isolation, creation, collision/cancel handling, popup, drafts, slash command, sidebar)."
)
