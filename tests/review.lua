-- Real Git review coverage: worktree/index separation, branch bases, edge paths, and feedback.
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.getcwd()
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
dir = vim.fn.resolve(dir)
local repo = dir .. "/review tree"
local function git(args)
	local command = { "git", "-c", "user.name=Aero Test", "-c", "user.email=aero@example.invalid", "-c", "commit.gpgsign=false" }
	vim.list_extend(command, args)
	local result = vim.system(command, { text = true }):wait()
	assert(result.code == 0, (result.stderr or "") .. (result.stdout or ""))
	return vim.trim(result.stdout or "")
end
local function await(start)
	local done, value, err, truncated
	start(function(v, e, t) done, value, err, truncated = true, v, e, t end)
	assert(vim.wait(5000, function() return done end, 10), "review query timed out")
	return value, err, truncated
end
local service = require("aero.review.git")
local function collect(base, path)
	local result, err = await(function(cb) service.collect(path or repo, base, cb) end)
	assert(result, err)
	return result
end
local function diff(snapshot, item)
	local result, err, truncated = await(function(cb) service.diff(snapshot, item, cb) end)
	assert(result, err)
	return result, truncated
end
local function find(snapshot, kind, path)
	for _, item in ipairs(snapshot.items) do
		if item.kind == kind and item.path == path then return item end
	end
	error("missing " .. kind .. " " .. path .. ": " .. vim.inspect(snapshot.items))
end
git({ "init", "--initial-branch=main", repo })
vim.fn.writefile({ "initial", "keep" }, repo .. "/code.lua")
git({ "-C", repo, "add", "." })
local unborn = collect()
assert(find(unborn, "staged", "code.lua").status == "A")
assert(diff(unborn, unborn.items[1]):find("+initial", 1, true))
git({ "-C", repo, "commit", "-m", "initial" })
assert(#collect().items == 0)
git({ "-C", repo, "checkout", "-b", "feature" })
vim.fn.writefile({ "branch committed", "keep" }, repo .. "/code.lua")
git({ "-C", repo, "commit", "-am", "feature" })
local feature_head = git({ "-C", repo, "rev-parse", "HEAD" })
-- Diverge the base: branch review must use the merge-base, not main's tip.
git({ "-C", repo, "checkout", "main" })
vim.fn.writefile({ "base-only" }, repo .. "/base.txt")
git({ "-C", repo, "add", "." })
git({ "-C", repo, "commit", "-m", "base moves" })
git({ "-C", repo, "checkout", "feature" })
vim.fn.writefile({ "staged", "keep" }, repo .. "/code.lua")
git({ "-C", repo, "add", "code.lua" })
vim.fn.writefile({ "unstaged", "keep" }, repo .. "/code.lua")
local odd = "odd\tname\r\n[1].lua"
vim.fn.writefile({ "untracked" }, repo .. "/" .. odd)
vim.fn.writefile({ "a\nb" }, repo .. "/binary.bin", "b")
local snapshot = collect()
assert(diff(snapshot, find(snapshot, "staged", "code.lua")):find("+staged", 1, true))
local unstaged = diff(snapshot, find(snapshot, "unstaged", "code.lua"))
assert(unstaged:find("-staged", 1, true) and unstaged:find("+unstaged", 1, true))
assert(diff(snapshot, find(snapshot, "untracked", odd)):find("+untracked", 1, true))
assert(diff(snapshot, find(snapshot, "untracked", "binary.bin")):find("Binary files", 1, true))
local branch = collect("main")
assert(#branch.items == 1 and branch.head == feature_head)
assert(diff(branch, find(branch, "branch", "code.lua")):find("+branch committed", 1, true))
local invalid, invalid_err = await(function(cb) service.collect(repo, "--not-a-ref", cb) end)
assert(not invalid and invalid_err)
-- Literal pathspecs must not interpret glob characters in names.
vim.fn.writefile({ "literal" }, repo .. "/[abc].txt")
vim.fn.writefile({ "other" }, repo .. "/a.txt")
git({ "-C", repo, "add", "." })
git({ "-C", repo, "commit", "-m", "paths" })
vim.fn.writefile({ "literal changed" }, repo .. "/[abc].txt")
vim.fn.writefile({ "other changed" }, repo .. "/a.txt")
snapshot = collect()
local literal = diff(snapshot, find(snapshot, "unstaged", "[abc].txt"))
assert(literal:find("+literal changed", 1, true) and not literal:find("other changed", 1, true))
-- Renames and deletions preserve their correct diff paths.
git({ "-C", repo, "mv", "code.lua", "renamed.lua" })
snapshot = collect()
local renamed = find(snapshot, "staged", "renamed.lua")
assert(renamed.old_path == "code.lua" and diff(snapshot, renamed):find("rename from code.lua", 1, true))
vim.fn.delete(repo .. "/a.txt")
assert(find(collect(), "unstaged", "a.txt").status == "D")
-- Frozen branch previews remain tied to the collected HEAD.
assert(diff(branch, branch.items[1]):find("+branch committed", 1, true))

local aero = require("aero")
aero.setup({
	state_file = dir .. "/state.json", animation = false, start_insert = false, persist_buffers = false,
	agents = { fixture = { type = "acp", cmd = { "python3", root .. "/tests/fixtures/acp.py", "save" } } },
})
vim.cmd.runtime("plugin/aero.lua")
api.nvim_win_set_width(0, 100)
vim.o.columns, vim.o.lines = 120, 40
vim.cmd.cd(vim.fn.fnameescape(repo))
local source_win = api.nvim_get_current_win()
local view = aero.review()
assert(vim.wait(5000, function() return view.snapshot and view.output end, 10))
assert(view.path == repo and vim.bo[view.diff_buf].modifiable == false)
for i, row in ipairs(view.rows) do
	local item = row.node.item
	if item and item.kind == "unstaged" and item.path == "[abc].txt" then
		api.nvim_win_set_cursor(view.list_win, { i, 0 })
		view.preview()
		assert(vim.wait(5000, function() return view.output end, 10))
	end
end
local marks = api.nvim_buf_get_extmarks(view.diff_buf, api.nvim_create_namespace("Aero.review.diff"), 0, -1, { details = true })
local added, removed = false, false
for _, mark in ipairs(marks) do
	local text = api.nvim_buf_get_lines(view.diff_buf, mark[2], mark[2] + 1, false)[1]
	assert(text:sub(1, 1) == "+" or text:sub(1, 1) == "-")
	assert(not text:match("^%+%+%+ ") and not text:match("^%-%-%- "), "file headers were colored as changes")
	added = added or mark[4].hl_group == "AeroReviewAdd"
	removed = removed or mark[4].hl_group == "AeroReviewDelete"
end
assert(added and removed, "review must highlight additions and deletions separately")
local custom = 0x123456
api.nvim_set_hl(0, "AeroReviewAdd", { fg = custom })
api.nvim_exec_autocmds("ColorScheme", {})
assert(api.nvim_get_hl(0, { name = "AeroReviewAdd", link = false }).fg == custom, "review replaced a custom highlight")
api.nvim_set_hl(0, "AeroReviewAdd", { fg = "#98c379" })
assert(vim.fn.getcompletion("Aero rev", "cmdline")[1] == "review")
api.nvim_exec_autocmds("FocusGained", {})
assert(view.stale and vim.wo[view.diff_win].winbar:find("STALE", 1, true))
-- Feedback uses the selected worktree, preserves text for composition, never sends a turn.
local session = require("aero.session")
local old_list, old_all, old_append = session.list, session.all, require("aero.compose").append
local recipient = { name = "reviewer", agent = "opencode-acp", worktree = repo, chat = { state = "ready" } }
session.list = function(path) assert(path == repo); return { recipient } end
session.all = function() return { recipient } end
local appended
require("aero.compose").append = function(s, text) assert(s == recipient); appended = text; return true end
api.nvim_set_current_win(view.diff_win)
view.feedback(false)
appended = table.concat(api.nvim_buf_get_lines(view.feedback_buf, 0, -1, false), "\n")
assert(not view.closed and appended:find("Review feedback for worktree", 1, true) and appended:find("```diff", 1, true))
assert(appended:find("may be stale", 1, true))
view.close()
session.list, session.all, require("aero.compose").append = old_list, old_all, old_append

view = aero.review(repo, "main")
assert(vim.wait(5000, function() return view.snapshot and view.output end, 10))
assert(view.snapshot.base == "main")
view.open_file()
assert(view.closed and api.nvim_buf_get_name(0) == repo .. "/[abc].txt")
local unsaved_buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(unsaved_buf, 0, -1, false, { "unsaved buffer content" })
view = aero.review(repo, "main")
assert(vim.wait(5000, function() return view.snapshot and view.output end, 10))
view.open_file()
assert(api.nvim_get_current_buf() == unsaved_buf and vim.bo[unsaved_buf].modified)
assert(api.nvim_buf_get_lines(unsaved_buf, 0, 1, false)[1] == "unsaved buffer content")
-- Closing during in-flight queries must not touch wiped buffers or steal focus later.
view = aero.review(repo)
view.close()
vim.wait(200)
assert(api.nvim_get_current_buf() ~= view.list_buf)

-- Real ACP composition preserves a draft and does not submit the quoted hunk.
local content = {}
for i = 1, 30 do content[i] = "original " .. i end
vim.fn.writefile(content, repo .. "/hunks.txt")
git({ "-C", repo, "add", "hunks.txt" })
git({ "-C", repo, "commit", "-m", "hunk fixture" })
content[1], content[30] = "first change", "last change"
vim.fn.writefile(content, repo .. "/hunks.txt")
local real = session.create(repo, "fixture")
require("aero.panel").show(real)
assert(vim.wait(5000, function() return real.chat.state == "ready" end, 10))
local prompt = real.chat:get_prompt_buf()
api.nvim_buf_set_lines(prompt, 0, -1, false, { "Keep this draft." })
local function hunk_view()
	local result = aero.review(repo)
	assert(vim.wait(5000, function() return result.snapshot end, 10))
	for i, row in ipairs(result.rows) do
		if row.node.item and row.node.item.path == "hunks.txt" then api.nvim_win_set_cursor(result.list_win, { i, 0 }); break end
	end
	result.preview()
	assert(vim.wait(5000, function() return result.output and result.output:find("+last change", 1, true) end, 10))
	api.nvim_set_current_win(result.diff_win)
	return result
end
view = hunk_view()
local last_line
for i, text in ipairs(api.nvim_buf_get_lines(view.diff_buf, 0, -1, false)) do
	if text == "+last change" then last_line = i end
end
api.nvim_win_set_cursor(view.diff_win, { last_line, 0 })
require("aero.quote").quote()
local draft = table.concat(api.nvim_buf_get_lines(view.feedback_buf, 0, -1, false), "\n")
assert(not draft:find("Keep this draft.", 1, true) and draft:find("+last change", 1, true))
assert(api.nvim_buf_get_lines(prompt, 0, -1, false)[1] == "Keep this draft.")
assert(not draft:find("+first change", 1, true), "hunk quote included another hunk")
assert(#real.chat.blocks == 0 and #real.chat.queue == 0, "review submitted a prompt")
assert(not view.closed and api.nvim_win_get_buf(view.feedback_win) == view.feedback_buf)
assert(api.nvim_win_get_config(view.feedback_win).relative == "editor")
-- Sending closes only the composer and leaves the review ready for another quote.
api.nvim_buf_set_lines(view.feedback_buf, -1, -1, false, { "/send" })
api.nvim_win_set_cursor(view.feedback_win, { api.nvim_buf_line_count(view.feedback_buf), 0 })
api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
assert(not view.closed and api.nvim_win_is_valid(view.diff_win))
assert(not api.nvim_win_is_valid(view.feedback_win))
assert(api.nvim_get_current_win() == view.diff_win)
assert(api.nvim_buf_get_lines(prompt, 0, -1, false)[1] == "Keep this draft.")
view.close()
view = hunk_view()
api.nvim_win_set_cursor(view.diff_win, { last_line, 0 })
vim.cmd.normal({ args = { "V" }, bang = true })
local before_register = vim.fn.getreg('"')
api.nvim_feedkeys("a", "xt", false)
assert(not view.closed and vim.fn.getreg('"') == before_register)
assert(api.nvim_win_is_valid(view.feedback_win))
view.close()
local terminal_recipient = { name = "terminal reviewer", agent = "opencode", worktree = repo, job = 12345 }
session.list = function() return { terminal_recipient } end
session.all = function() return { terminal_recipient } end
view = hunk_view()
api.nvim_win_set_cursor(view.diff_win, { last_line, 0 })
require("aero.quote").quote()
assert(api.nvim_get_current_win() == view.feedback_win)
assert(api.nvim_win_get_config(view.feedback_win).relative == "editor")
local old_chansend, sent = vim.fn.chansend
vim.fn.chansend = function(job, text) assert(job == 12345); sent = text; return #text end
api.nvim_buf_set_lines(view.feedback_buf, -1, -1, false, { "/send" })
api.nvim_win_set_cursor(view.feedback_win, { api.nvim_buf_line_count(view.feedback_buf), 0 })
api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
vim.fn.chansend = old_chansend
assert(sent:find("+last change", 1, true) and sent:sub(-1) == "\r")
assert(not view.closed and api.nvim_get_current_win() == view.diff_win)
view.close()
session.list, session.all = old_list, old_all

-- Review navigation follows project folders, keeping each file's Git variant distinct.
vim.fn.mkdir(repo .. "/src/api", "p")
vim.fn.mkdir(repo .. "/src/ui", "p")
vim.fn.mkdir(repo .. "/docs", "p")
vim.fn.writefile({ "api base" }, repo .. "/src/api/shared.lua")
vim.fn.writefile({ "ui base" }, repo .. "/src/ui/shared.lua")
vim.fn.writefile({ "rename me" }, repo .. "/src/api/original.lua")
vim.fn.writefile({ "delete me" }, repo .. "/docs/deleted.md")
git({ "-C", repo, "add", "src", "docs" })
git({ "-C", repo, "commit", "-m", "nested review fixture" })
vim.fn.writefile({ "api staged" }, repo .. "/src/api/shared.lua")
git({ "-C", repo, "add", "src/api/shared.lua" })
vim.fn.writefile({ "api working" }, repo .. "/src/api/shared.lua")
vim.fn.writefile({ "ui working" }, repo .. "/src/ui/shared.lua")
git({ "-C", repo, "mv", "src/api/original.lua", "src/api/renamed.lua" })
vim.fn.delete(repo .. "/docs/deleted.md")
vim.fn.mkdir(repo .. "/src/new/helpers", "p")
vim.fn.writefile({ "new helper" }, repo .. "/src/new/helpers/new.lua")
view = aero.review(repo)
assert(vim.wait(5000, function() return view.snapshot and view.output end, 10))
local function tree_row(path, kind)
	for i, row in ipairs(view.rows) do
		if row.node.path == path and (kind == "directory" and row.node.kind == kind
			or row.node.item and row.node.item.kind == kind) then return i, row end
	end
	error("missing tree entry: " .. path .. " " .. kind)
end
local function choose(path, kind)
	local i = tree_row(path, kind)
	api.nvim_set_current_win(view.list_win)
	api.nvim_win_set_cursor(view.list_win, { i, 0 })
	view.preview()
end
local function list_key(key)
	api.nvim_set_current_win(view.list_win)
	api.nvim_feedkeys(api.nvim_replace_termcodes(key, true, false, true), "xt", false)
end
local staged_row, staged_entry = tree_row("src/api/shared.lua", "staged")
local working_row = tree_row("src/api/shared.lua", "unstaged")
assert(working_row == staged_row + 1, "staged and unstaged variants should stay together")
assert(view.rows[staged_entry.parent].node.path == "src/api")
assert(view.rows[view.rows[staged_entry.parent].parent].node.path == "src")
local leaf_text = api.nvim_buf_get_lines(view.list_buf, staged_row - 1, staged_row, false)[1]
assert(leaf_text:find("shared.lua [staged]", 1, true) and not leaf_text:find("src/api/", 1, true))
local rename_row = tree_row("src/api/renamed.lua", "staged")
assert(api.nvim_buf_get_lines(view.list_buf, rename_row - 1, rename_row, false)[1]:find("from src/api/original.lua", 1, true))
local _, deleted_entry = tree_row("docs/deleted.md", "unstaged")
assert(view.rows[deleted_entry.parent].node.path == "docs")
local _, new_entry = tree_row("src/new/helpers/new.lua", "untracked")
assert(view.rows[new_entry.parent].node.path == "src/new/helpers")
local status_ns = api.nvim_create_namespace("Aero.review.status")
for _, case in ipairs({
	{ "src/api/shared.lua", "unstaged", "Modified", "AeroReviewChange" },
	{ "src/api/renamed.lua", "staged", "Renamed", "AeroReviewChange" },
	{ "docs/deleted.md", "unstaged", "Deleted", "AeroReviewDelete" },
	{ "src/new/helpers/new.lua", "untracked", "Untracked", "AeroReviewAdd" },
}) do
	local row = tree_row(case[1], case[2])
	assert(api.nvim_buf_get_lines(view.list_buf, row - 1, row, false)[1]:find("[" .. case[3] .. "]", 1, true))
	local marks = api.nvim_buf_get_extmarks(view.list_buf, status_ns, { row - 1, 0 }, { row - 1, -1 }, { details = true })
	assert(#marks == 1 and marks[1][4].hl_group == case[4])
end
local added_label, added_hl = require("aero.review.tree").status({ kind = "staged", status = "A" })
assert(added_label == "Added" and added_hl == "AeroReviewAdd")

choose("src/api/shared.lua", "staged")
assert(vim.wait(5000, function() return view.output and view.output:find("+api staged", 1, true) end, 10))
choose("src/api/shared.lua", "unstaged")
assert(vim.wait(5000, function() return view.output and view.output:find("+api working", 1, true) end, 10))
assert(view.output:find("-api staged", 1, true) and not view.output:find("ui working", 1, true))
list_key("h")
assert(view.rows[api.nvim_win_get_cursor(view.list_win)[1]].node.path == "src/api")
assert(view.item == nil and view.output == nil)
list_key("h")
assert(view.collapsed["src/api"], "h should collapse an expanded directory")
for _, row in ipairs(view.rows) do assert(not row.node.item or not row.node.path:match("^src/api/")) end
local before_refresh = view.snapshot
view.refresh()
assert(vim.wait(5000, function() return view.snapshot and view.snapshot ~= before_refresh end, 10))
assert(view.collapsed["src/api"] and view.rows[api.nvim_win_get_cursor(view.list_win)[1]].node.path == "src/api")
list_key("l")
assert(not view.collapsed["src/api"])
list_key("l")
assert(view.rows[view.rows[api.nvim_win_get_cursor(view.list_win)[1]].parent].node.path == "src/api")
list_key("h")
list_key("<CR>")
assert(view.collapsed["src/api"] and api.nvim_get_current_win() == view.list_win)
list_key("<CR>")
assert(not view.collapsed["src/api"])

choose("src/api/shared.lua", "staged")
vim.fn.writefile({ "inserted earlier in tree" }, repo .. "/src/api/aaa.lua")
before_refresh = view.snapshot
view.refresh()
assert(vim.wait(5000, function() return view.snapshot and view.snapshot ~= before_refresh and view.output end, 10))
assert(view.item.path == "src/api/shared.lua" and view.item.kind == "staged", "refresh lost the selected Git variant")
choose("src/ui/shared.lua", "unstaged")
list_key("<CR>")
assert(api.nvim_get_current_win() == view.diff_win)
assert(vim.wait(5000, function() return view.output and view.output:find("+ui working", 1, true) end, 10))
view.feedback(false)
local nested_feedback = table.concat(api.nvim_buf_get_lines(view.feedback_buf, 0, -1, false), "\n")
assert(nested_feedback:find('File: "src/ui/shared.lua"', 1, true) and nested_feedback:find("+ui working", 1, true))
view.close()
view = aero.review(repo, "main")
assert(vim.wait(5000, function() return view.snapshot and view.output end, 10))
choose("src/ui/shared.lua", "branch")
assert(vim.wait(5000, function() return view.output and view.output:find("+ui base", 1, true) end, 10))
assert(not view.output:find("ui working", 1, true))
view.close()
session.delete(real)

-- Output is bounded without converting a successful no-index diff exit (1) into an error.
vim.fn.writefile({ string.rep("large line ", 120000) }, repo .. "/large.txt")
snapshot = collect()
local bounded, truncated = diff(snapshot, find(snapshot, "untracked", "large.txt"))
assert(truncated and #bounded == 1024 * 1024)

-- Dashboard selection targets another linked checkout, not the current tab's agent.
local other = dir .. "/other checkout"
git({ "-C", repo, "worktree", "add", "-b", "review-other", other, "HEAD" })
vim.fn.writefile({ "other worktree" }, other .. "/other.txt")
require("aero.store").add_workspace(repo)
aero.open()
local dashboard_win = api.nvim_get_current_win()
local other_row
assert(vim.wait(5000, function()
	for i, line in ipairs(api.nvim_buf_get_lines(api.nvim_win_get_buf(dashboard_win), 0, -1, false)) do
		if line:find("review-other", 1, true) then other_row = i; return true end
	end
end, 10))
api.nvim_win_set_cursor(dashboard_win, { other_row, 0 })
assert(type(vim.fn.maparg("gr", "n", false, true).callback) == "function")
view = aero.review()
assert(vim.wait(5000, function() return view.snapshot and view.output end, 10))
assert(view.path == other and view.item.path == "other.txt")
view.close()
api.nvim_win_set_cursor(dashboard_win, { 1, 0 })
local old_notify, message = vim.notify
vim.notify = function(text) message = text end
assert(aero.review() == nil and message:find("move the cursor", 1, true))
vim.notify = old_notify

require("aero.buffers").flush()
vim.fn.delete(dir, "rf")
print("Review tests passed (real Git, unborn HEAD, staged/unstaged, untracked/binary, literal paths, renames/deletions, merge-base, frozen HEAD, folder tree, collapse/navigation, refresh selection, feedback, cleanup).")
