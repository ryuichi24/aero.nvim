-- Run: nvim --headless -u NONE -l tests/tasks_removed.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = require("aero.storage").canonical(root)
local notices = {}
vim.notify = function(message)
	table.insert(notices, message)
end
require("aero.git").list = function()
	return { { path = root, branch = "main" } }
end
require("aero.git").main_root = function()
	return root
end
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	worktree_tabs = false,
	tasks = { directory = "worktree", states = { "todo", "done" } },
})
vim.cmd.runtime("plugin/aero.lua")
local ws = require("aero.store").add_workspace(root)
local tasks, storage = require("aero.tasks"), require("aero.tasks.storage")
local source = assert(tasks.create_board(ws, "Original"))
local target = assert(tasks.create_board(ws, "Selected"))
assert(tasks.add_state(ws, target.path, "review queue"))
local ticket = assert(
	tasks.create_ticket(
		ws,
		source.path,
		"todo",
		"Retained requirements",
		{ priority = "high" },
		{ "Keep implementation notes." }
	)
)
assert(tasks.remove_ticket(ws, source.path, ticket.path))
local removed = tasks.list_removed(ws)
assert(#removed == 1 and removed[1].title == ticket.metadata.title and removed[1].board_title == "Original")
assert(#tasks.read_board(ws, source.path).diagnostics == 0, "removed tickets were treated as errors")
local original_ticket, source_text, target_text =
	storage.read(ticket.path), storage.read(source.path), storage.read(target.path)
local viewmod = require("aero.tasks.view")
local view = assert(viewmod.open(ws, source.path))
assert(vim.wo.winbar:find("Removed tickets: 1 (go)", 1, true))

-- Cancelling any picker stage leaves both boards and the ticket untouched.
local function choose(items, opts)
	if opts.prompt:find("Removed tickets", 1, true) then
		return items[1]
	end
	if opts.prompt == "Restore into board" then
		for _, board in ipairs(items) do
			if board.path == target.path then
				return board
			end
		end
	end
	if opts.prompt == "Restore into state" then
		return "review queue"
	end
end
for cancel = 1, 2 do
	local step = 0
	vim.ui.select = function(items, opts, callback)
		step = step + 1
		if step == cancel then
			callback(nil)
		else
			callback(choose(items, opts))
		end
	end
	viewmod.actions(view).recover()
	vim.fn.maparg("<CR>", "n", false, true).callback()
	vim.fn.maparg("q", "n", false, true).callback()
	assert(storage.read(source.path) == source_text and storage.read(target.path) == target_text)
	assert(storage.read(ticket.path) == original_ticket)
end

-- Unsaved ticket edits block cross-board transfer, including hidden buffers.
local ticket_buf = vim.fn.bufadd(ticket.path)
vim.fn.bufload(ticket_buf)
api.nvim_buf_set_lines(ticket_buf, -1, -1, false, { "Human draft" })
local result, err = tasks.recover_ticket(ws, source.path, ticket.path, target.path, "review queue")
assert(not result and err:find("unsaved edits", 1, true))
vim.bo[ticket_buf].modified = false

-- A failed destination board commit must preserve the original and clean its copy.
local destination = vim.fs.joinpath(vim.fs.dirname(target.path), "tickets", vim.fs.basename(ticket.path))
local collision = original_ticket:gsub(vim.pesc(ticket.metadata.id), storage.id("task"))
assert(storage.create(destination, collision))
result, err = tasks.recover_ticket(ws, source.path, ticket.path, target.path, "review queue")
assert(not result and storage.read(destination) == collision and storage.read(ticket.path) == original_ticket)
assert(storage.read(target.path) == target_text)
assert(vim.uv.fs_unlink(destination))
local write = storage.write
storage.write = function(path, ...)
	if path == target.path then
		return nil, "injected board write failure"
	end
	return write(path, ...)
end
result, err = tasks.recover_ticket(ws, source.path, ticket.path, target.path, "review queue")
storage.write = write
assert(not result and err:find("injected board write failure", 1, true))
assert(storage.read(ticket.path) == original_ticket and not vim.uv.fs_stat(destination))
assert(storage.read(target.path) == target_text)

-- Destination projection drafts are checked after the asynchronous selections.
local target_view = assert(viewmod.open(ws, target.path))
vim.ui.select = function(items, opts, callback)
	if opts.prompt == "Restore into state" then
		api.nvim_buf_set_lines(target_view.columns[1].buf, -1, -1, false, { "Unsubmitted title" })
	end
	callback(choose(items, opts))
end
require("aero.tasks.ui").removed(ws, source.path)
vim.fn.maparg("<CR>", "n", false, true).callback()
vim.fn.maparg("q", "n", false, true).callback()
assert(storage.read(target.path) == target_text and storage.read(ticket.path) == original_ticket)
assert(viewmod.dirty(target_view))
viewmod.render(target_view, true)

-- The dashboard exposes the workspace list and titles; recovery does not steal focus.
require("aero").open()
local dashboard, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
local found
for row, line in ipairs(api.nvim_buf_get_lines(dashboard, 0, -1, false)) do
	if line:find("Removed tickets", 1, true) then
		found = row
		break
	end
end
assert(found, "dashboard has no removed-ticket entry")
vim.ui.select = function(items, opts, callback)
	if opts.prompt:find("Removed tickets", 1, true) then
		assert(opts.format_item(items[1]):find("Retained requirements · from Original", 1, true))
	end
	callback(choose(items, opts))
end
api.nvim_win_set_cursor(win, { found, 0 })
assert(vim.uv.fs_chmod(ticket.path, 384))
vim.fn.maparg("<CR>", "n", false, true).callback()
assert(api.nvim_get_current_line():find("Retained requirements · from Original", 1, true))
vim.fn.maparg("<CR>", "n", false, true).callback()
vim.fn.maparg("q", "n", false, true).callback()
assert(api.nvim_get_current_win() == win)
assert(#tasks.list_removed(ws) == 0)
assert(not vim.uv.fs_stat(ticket.path) and vim.uv.fs_stat(destination))
assert(vim.uv.fs_stat(destination).mode % 512 == 384, "transfer lost ticket permissions")
local restored = tasks.read_board(ws, target.path)
assert(restored.states[3].entries[1].path == destination)
local updated = tasks.read_ticket(target.path, destination)
assert(
	updated.metadata.id == ticket.metadata.id
		and updated.metadata.priority == "high"
		and updated.metadata.state == "review queue"
)
assert(updated.text:find("Keep implementation notes.", 1, true))
assert(storage.read(source.path) == source_text)
assert(api.nvim_buf_get_name(ticket_buf) == destination, "loaded ticket buffer did not follow the transfer")
assert(not viewmod.status(source.path).dirty and not viewmod.status(target.path).dirty)
assert(
	not tasks.recover_ticket(ws, target.path, destination, source.path, "todo"),
	"referenced ticket was recovered as removed"
)
assert(vim.tbl_contains(vim.fn.getcompletion("Aero ticket ", "cmdline"), "removed"))

-- Same-board recovery retains the path and uses the chosen state.
assert(tasks.remove_ticket(ws, target.path, destination))
assert(tasks.recover_ticket(ws, target.path, destination, target.path, "todo"))
assert(tasks.read_board(ws, target.path).states[1].entries[1].path == destination)
assert(#tasks.list_removed(ws) == 0)

-- A post-commit unlink failure reports its retained source rather than losing data.
local retained_ticket = assert(tasks.create_ticket(ws, source.path, "todo", "Retain on unlink failure"))
assert(tasks.remove_ticket(ws, source.path, retained_ticket.path))
local retained_text = storage.read(retained_ticket.path)
local unlink = vim.uv.fs_unlink
vim.uv.fs_unlink = function(path, ...)
	if path == retained_ticket.path then
		return nil, "injected unlink failure"
	end
	return unlink(path, ...)
end
result, err = tasks.recover_ticket(ws, source.path, retained_ticket.path, target.path, "done")
vim.uv.fs_unlink = unlink
assert(result and result.warning:find("injected unlink failure", 1, true), err)
assert(storage.read(retained_ticket.path) == retained_text and vim.uv.fs_stat(result.path))
assert(tasks.read_board(ws, target.path).states[2].entries[1].path == result.path)

-- Invalid removed documents remain discoverable but cannot be recovered.
local invalid_path = vim.fs.joinpath(vim.fs.dirname(source.path), "tickets", "invalid.md")
assert(storage.create(invalid_path, "Not a valid Aero ticket.\n"))
local invalid
for _, item in ipairs(tasks.list_removed(ws)) do
	if item.path == invalid_path then
		invalid = item
	end
end
assert(invalid and invalid.error)
assert(not tasks.recover_ticket(ws, source.path, invalid_path, target.path, "todo"))
assert(storage.read(invalid_path) == "Not a valid Aero ticket.\n")

-- Removed tickets are edited with native motions and deleted only by :w.
local ui = require("aero.tasks.ui")
ui.removed(ws)
local removed_buf = api.nvim_get_current_buf()
local removed_win = api.nvim_get_current_win()
local removed_tab = api.nvim_get_current_tabpage()
assert(#api.nvim_tabpage_list_wins(removed_tab) == 1, "removed list does not have a dedicated tab")
assert(api.nvim_win_get_width(removed_win) == vim.o.columns, "removed list is constrained by the sidebar")
assert(vim.t[removed_tab].aero_removed_workspace == ws.root)
assert(require("aero.tabs").find(ws.root) ~= removed_tab, "removed list was reused as a code tab")
local window_count = #api.nvim_list_wins()
ui.removed(ws)
assert(api.nvim_get_current_buf() == removed_buf and api.nvim_get_current_win() == removed_win)
assert(#api.nvim_list_wins() == window_count, "reopening created a duplicate window")
-- Reopening from the board updates the existing clean list with newly removed tickets.
local latest = assert(tasks.create_ticket(ws, source.path, "todo", "Newly removed"))
assert(tasks.remove_ticket(ws, source.path, latest.path))
viewmod.open(ws, source.path)
local before_reopen = #api.nvim_list_wins()
ui.removed(ws)
assert(api.nvim_get_current_buf() == removed_buf and api.nvim_get_current_win() == removed_win)
assert(#api.nvim_list_wins() == before_reopen)
assert(api.nvim_get_current_tabpage() == removed_tab, "reopening created a duplicate tab")
assert(table.concat(api.nvim_buf_get_lines(removed_buf, 0, -1, false), "\n"):find("Newly removed", 1, true))
local function find_row(text)
	for row, line in ipairs(api.nvim_buf_get_lines(removed_buf, 0, -1, false)) do
		if line:find(text, 1, true) then
			return row
		end
	end
	error("missing removed row: " .. text)
end
local row = find_row("invalid.md")
api.nvim_win_set_cursor(0, { row, 0 })
vim.cmd("normal! dd")
assert(storage.read(invalid_path), "motion deleted a file before save")
local draft = api.nvim_buf_get_lines(removed_buf, 0, -1, false)
ui.removed(ws)
assert(vim.bo[removed_buf].modified and vim.deep_equal(draft, api.nvim_buf_get_lines(removed_buf, 0, -1, false)))
vim.fn.maparg("q", "n", false, true).callback()
assert(not api.nvim_tabpage_is_valid(removed_tab), "q did not close the removed-ticket tab")
ui.removed(ws)
assert(api.nvim_get_current_buf() == removed_buf and vim.bo[removed_buf].modified)
assert(vim.deep_equal(draft, api.nvim_buf_get_lines(removed_buf, 0, -1, false)), "closing lost the deletion draft")
assert(#api.nvim_tabpage_list_wins(0) == 1 and api.nvim_win_get_width(0) == vim.o.columns)
vim.cmd("normal! u")
assert(find_row("invalid.md"))
-- Stale files reject the entire deletion draft.
api.nvim_win_set_cursor(0, { find_row("invalid.md"), 0 })
vim.cmd("normal! dd")
assert(storage.write(invalid_path, "Not a valid Aero ticket.\n", "Changed externally.\n"))
vim.cmd.write()
assert(storage.read(invalid_path) == "Changed externally.\n" and vim.bo[removed_buf].modified)
vim.fn.maparg("R", "n", false, true).callback()
api.nvim_win_set_cursor(0, { find_row("invalid.md"), 0 })
vim.cmd("normal! dd")
vim.cmd.write()
assert(not vim.uv.fs_stat(invalid_path) and not vim.bo[removed_buf].modified)
assert(not vim.tbl_contains(
	vim.tbl_map(function(item)
		return item.path
	end, tasks.list_removed(ws)),
	invalid_path
))
-- A restored ticket cannot be deleted by a stale removed-list draft.
vim.fn.maparg("R", "n", false, true).callback()
api.nvim_win_set_cursor(0, { find_row("Retain on unlink failure"), 0 })
vim.cmd("normal! dd")
assert(tasks.recover_ticket(ws, source.path, retained_ticket.path, source.path, "todo"))
vim.cmd.write()
assert(vim.uv.fs_stat(retained_ticket.path) and vim.bo[removed_buf].modified)
-- Bulk deletion is prevalidated, including unsaved hidden ticket buffers.
local first = assert(tasks.create_ticket(ws, source.path, "todo", "Bulk first"))
local second = assert(tasks.create_ticket(ws, source.path, "todo", "Bulk second"))
local spare = assert(tasks.create_ticket(ws, source.path, "todo", "Keep this removed ticket"))
assert(tasks.remove_ticket(ws, source.path, first.path))
assert(tasks.remove_ticket(ws, source.path, second.path))
assert(tasks.remove_ticket(ws, source.path, spare.path))
vim.fn.maparg("R", "n", false, true).callback()
local hidden = vim.fn.bufadd(second.path)
vim.fn.bufload(hidden)
api.nvim_buf_set_lines(hidden, -1, -1, false, { "Unsaved requirements" })
api.nvim_win_set_cursor(0, { find_row("Bulk first"), 0 })
vim.cmd("normal! 2dd")
vim.cmd.write()
assert(vim.uv.fs_stat(first.path) and vim.uv.fs_stat(second.path), "batch was not prevalidated")
assert(vim.bo[removed_buf].modified)
vim.bo[hidden].modified = false
vim.cmd.write()
assert(not vim.uv.fs_stat(first.path) and not vim.uv.fs_stat(second.path))
assert(not api.nvim_buf_is_valid(hidden), "deleted ticket buffer was left behind")
-- Editing a label must not accidentally request deletion.
local lines = api.nvim_buf_get_lines(removed_buf, 0, -1, false)
if lines[1] ~= "" then
	api.nvim_buf_set_lines(removed_buf, 0, 1, false, { "Unknown row" })
	local count = #tasks.list_removed(ws)
	vim.cmd.write()
	assert(vim.bo[removed_buf].modified and #tasks.list_removed(ws) == count)
end
vim.fn.delete(root, "rf")
print("Removed-ticket tests passed (recovery, motion edits, undo, bulk deletion, drafts, stale files, invalid rows).")
vim.cmd("qa!")
