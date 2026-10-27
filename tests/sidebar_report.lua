vim.opt.rtp:prepend(vim.fn.getcwd())
local kind = vim.env.AERO_SIDEBAR_READER_KIND

if not kind then
	for _, name in ipairs({ "reports", "exports", "references", "nested-reference" }) do
		local result = vim.system(
			{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/sidebar_report.lua" },
			{
				env = { AERO_SIDEBAR_READER_KIND = name },
				text = true,
			}
		):wait(15000)

		assert(result.code == 0, name .. ": " .. (result.stderr or "") .. (result.stdout or ""))
	end

	print("sidebar reader entries: reports, exported logs, references, nested references: ok")
	return
end

local api = vim.api
local dir = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(dir .. "/repo", "p")
local repo, report = dir .. "/repo", dir .. "/report.md"
local label = "Window reuse report"

if kind == "nested-reference" then
	vim.fn.mkdir(dir .. "/reference-folder", "p")
	report = dir .. "/reference-folder/report.md"
	label = "report.md"
end

vim.fn.writefile({ "# Window reuse report" }, report)
local git = require("aero.git")
git.list = function()
	return { { path = repo, branch = "main" } }
end
git.remote_status = function(_, callback)
	callback({})
end
require("aero.reports").list = function()
	return kind == "reports" and { { path = report, name = label } } or {}
end
require("aero.exports").list = function()
	return kind == "exports" and { { path = report, name = label } } or {}
end
require("aero.reference").list = function()
	if kind == "references" then
		return { { path = report, name = label, kind = "file" } }
	elseif kind == "nested-reference" then
		return { { path = dir .. "/reference-folder", name = "reference-folder", kind = "directory" } }
	end

	return {}
end
local aero = require("aero")
aero.setup({ state_file = dir .. "/state.json", animation = false, companion = { auto_start = false } })
require("aero.store").add_workspace(repo)
local tab, editor, startup = api.nvim_get_current_tabpage(), api.nvim_get_current_win(), api.nvim_get_current_buf()
api.nvim_buf_set_name(startup, dir .. "/startup.txt")
api.nvim_buf_set_lines(startup, 0, -1, false, { "unsaved startup edits" })
aero.open()
local sidebar = api.nvim_get_current_win()
local panel = require("aero.panel").open()

local function key(lhs)
	for _, map in ipairs(api.nvim_buf_get_keymap(0, "n")) do
		if map.lhs == lhs then
			map.callback()
			return
		end
	end

	error("missing sidebar mapping: " .. lhs)
end

local function select_line(text)
	for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
		if line:find(text, 1, true) then
			api.nvim_win_set_cursor(0, { row, 0 })
			return
		end
	end

	error("missing sidebar item: " .. text)
end

select_line("main")
key("l")

if kind == "nested-reference" then
	select_line("reference-folder")
	key("<CR>")

	assert(api.nvim_get_current_win() == sidebar, "reference folder opened a reader instead of expanding")
	assert(#api.nvim_tabpage_list_wins(0) == 3, "reference folder created a window")
end

select_line(label)
key("<CR>")

assert(api.nvim_get_current_tabpage() == tab, "report abandoned the initial editor tab")
assert(api.nvim_get_current_win() == editor, "report did not reuse the initial editor")
assert(api.nvim_buf_get_name(0) == report)
assert(vim.w.aero_reader_kind == (kind == "nested-reference" and "references" or kind), "wrong reader slot selected")
assert(#api.nvim_tabpage_list_wins(0) == 3, "report added a second reader window")
assert(api.nvim_win_is_valid(sidebar) and api.nvim_win_is_valid(panel))
assert(vim.bo[startup].modified and api.nvim_buf_get_lines(startup, 0, -1, false)[1] == "unsaved startup edits")

for _ = 1, 2 do
	aero.close()
	aero.open()
	select_line(label)
	key("<CR>")

	assert(api.nvim_get_current_win() == editor)
	assert(#api.nvim_tabpage_list_wins(0) == 3, "reopening report duplicated the reader")
end

vim.fn.delete(dir, "rf")
print("sidebar report: ok")
vim.cmd("qa!")
