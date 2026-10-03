-- Run: nvim --headless -u NONE -l tests/tasks_view.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = require("aero.storage").canonical(root)
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
local tasks = require("aero.tasks")
local board =
	assert(tasks.create_board(ws, "UI board", { description = "A summary", tags = { "release" }, archived = true }))
local ticket = assert(
	tasks.create_ticket(
		ws,
		board.path,
		"todo",
		"Card title",
		{ priority = "urgent", assignees = { "ryu" }, due_date = "2000-01-01", estimate = 3, tags = { "feature" } }
	)
)
require("aero").open()
local source_dashboard = api.nvim_get_current_buf()
for i, line in ipairs(api.nvim_buf_get_lines(source_dashboard, 0, -1, false)) do
	if line:find("UI board", 1, true) then
		api.nvim_win_set_cursor(0, { i, 0 })
		break
	end
end
vim.fn.maparg("e", "n", false, true).callback()
assert(api.nvim_buf_get_name(0) == board.path)
local source_lines = api.nvim_buf_get_lines(0, 0, -1, false)
local title_line
for i, line in ipairs(source_lines) do
	if line:match("^title:") then
		title_line = i
		break
	end
end
source_lines[title_line] = 'title: "UI board edited"'
api.nvim_buf_set_lines(0, 0, -1, false, source_lines)
vim.cmd.write()
assert(
	vim.wait(1000, function()
		return table
			.concat(api.nvim_buf_get_lines(source_dashboard, 0, -1, false), "\n")
			:find("UI board edited", 1, true)
	end, 10),
	"direct source edit did not refresh sidebar"
)
source_lines[title_line] = 'title: "UI board"'
api.nvim_buf_set_lines(0, 0, -1, false, source_lines)
vim.cmd.write()
local feature = root .. "/feature"
vim.fn.mkdir(feature, "p")
vim.t.aero_worktree = feature
vim.ui.select = function(items, _, cb)
	cb(items[1])
end
vim.cmd("Aero board")
assert(require("aero.tasks.view").current().ws.root == root, "worktree did not resolve shared workspace boards")
assert(not vim.uv.fs_stat(feature .. "/.aero/tasks"), "boards duplicated under feature checkout")
require("aero").open()
local dashboard, dw = api.nvim_get_current_buf(), api.nvim_get_current_win()
local function row(label)
	for i, line in ipairs(api.nvim_buf_get_lines(dashboard, 0, -1, false)) do
		if line:find(label, 1, true) then
			return i
		end
	end
	error("missing sidebar row: " .. label)
end
local boards_row = row("Boards")
api.nvim_win_set_cursor(dw, { boards_row, 0 })
vim.fn.maparg("l", "n", false, true).callback()
assert(api.nvim_win_get_cursor(dw)[1] == row("UI board"))
vim.fn.maparg("h", "n", false, true).callback()
assert(api.nvim_win_get_cursor(dw)[1] == boards_row)
api.nvim_win_set_cursor(dw, { row("UI board"), 0 })
vim.fn.maparg("<CR>", "n", false, true).callback()
local view = require("aero.tasks.view").current()
assert(view and api.nvim_get_current_win() ~= dw and vim.bo[view.buf].modifiable)
local vw = api.nvim_get_current_win()
local function text()
	return table.concat(api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
end
assert(#view.columns == 2, "states did not receive separate buffers")
assert(text():find("Card title", 1, true))
assert(vim.wo[vw].winbar:find("[archived]", 1, true))
local decorations =
	vim.inspect(api.nvim_buf_get_extmarks(view.buf, api.nvim_create_namespace("Aero.tasks"), 0, -1, { details = true }))
for _, value in ipairs({ "urgent", "@ryu", "OVERDUE", "3 points", "#feature" }) do
	assert(decorations:find(value, 1, true), "missing card metadata: " .. value)
end
local function action(key)
	vim.fn.maparg(key, "n", false, true).callback()
end
action("<CR>")
assert(api.nvim_buf_get_name(0) == ticket.path, "ticket did not open in code pane")
assert(api.nvim_win_is_valid(dw) and api.nvim_win_get_buf(dw) == dashboard)
require("aero").open_board(ws, board.path)
vim.ui.select = function(items, opts, cb)
	cb(items[#items])
end
vim.cmd("Aero ticket move")
assert(#tasks.read_board(ws, board.path).states[2].entries == 0, "picker saved without :w")
vim.cmd.write()
assert(#tasks.read_board(ws, board.path).states[2].entries == 1)
require("aero.tasks.view").actions(view).next()
vim.ui.input = function(_, cb)
	cb("New from command")
end
vim.cmd("Aero ticket new")
assert(tasks.read_board(ws, board.path).count == 2)
assert(vim.tbl_contains(vim.fn.getcompletion("Aero ticket ", "cmdline"), "move"))
assert(vim.tbl_contains(vim.fn.getcompletion("Aero board ", "cmdline"), "new"))
-- Writes to ordinary Markdown refresh the derived view on return.
action("e")
assert(api.nvim_buf_get_name(0) == board.path)
local lines = api.nvim_buf_get_lines(0, 0, -1, false)
table.insert(lines, "## custom")
api.nvim_buf_set_lines(0, 0, -1, false, lines)
vim.cmd.write()
require("aero").open_board(ws, board.path)
assert(#view.board.states == 3 and view.columns[3].name == "custom")
local missing = vim.fs.dirname(board.path) .. "/tickets/missing.md"
local source = require("aero.tasks.storage").read(board.path)
vim.fn.writefile(vim.split(source .. "- [Missing](tickets/missing.md)\n", "\n", { trimempty = false }), board.path)
require("aero.tasks.view").render(view)
assert(#view.board.diagnostics > 0)
assert(table.concat(api.nvim_buf_get_lines(view.columns[3].buf, 0, -1, false), "\n"):find("Missing", 1, true))
assert(not vim.uv.fs_stat(missing))
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	tasks = { directory = "worktree", keymaps = { move = "gm", new = false } },
})
assert(vim.fn.maparg("m", "n", false, true).buffer ~= 1)
assert(type(vim.fn.maparg("gm", "n", false, true).callback) == "function")
assert(vim.fn.maparg("a", "n", false, true).buffer ~= 1)
vim.fn.delete(root, "rf")
print("Task UI tests passed (sidebar, editable columns, metadata, commands, source editing, refresh, diagnostics).")
vim.cmd.qa({ bang = true })
