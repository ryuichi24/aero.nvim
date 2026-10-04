-- AERO_MCP_EXECUTABLE=/absolute/aero-mcp nvim --headless -u NONE -l tests/tasks_agent.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local executable = assert(vim.env.AERO_MCP_EXECUTABLE)
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = require("aero.storage").canonical(root)
assert(vim.system({ "git", "init", root }):wait().code == 0)
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	start_insert = false,
	agents = { fixture = { type = "acp", cmd = { "python3", vim.fn.getcwd() .. "/tests/fixtures/tasks_acp.py" } } },
	tasks = {
		directory = "worktree",
		states = { "todo", "in progress", "review" },
		agent = { enabled = true, executable = executable, adapters = { "fixture" } },
	},
})
local ws = { root = root }
local tasks = require("aero.tasks")
local board = assert(tasks.create_board(ws, "Assignment"))
local ticket = assert(tasks.create_ticket(ws, board.path, "todo", "Implement"))
local view = require("aero.tasks.view").open(ws, board.path)
local board_tab = vim.api.nvim_get_current_tabpage()
vim.ui.select = function(_, _, callback)
	callback(nil)
end
require("aero.tasks.agent").work()
assert(#require("aero.session").all() == 0 and vim.api.nvim_get_current_tabpage() == board_tab)
vim.ui.select = function(items, _, callback)
	callback(items[1])
end
vim.ui.input = function(_, callback)
	callback(nil)
end
require("aero.tasks.agent").work()
assert(#require("aero.session").all() == 0 and vim.api.nvim_get_current_tabpage() == board_tab)
vim.ui.select = function(items, _, callback)
	callback(items[1])
end
vim.ui.input = function(_, callback)
	callback("Ticket session")
end
require("aero.tasks.agent").work()
local sessions = require("aero.session")
local s = assert(sessions.list(root)[1])
assert(s.task_binding and s.mcp_servers and s.key == s.task_binding.session_key)
assert(vim.api.nvim_get_current_tabpage() ~= board_tab and not vim.t[board_tab].aero_worktree)
assert(vim.api.nvim_buf_is_valid(view.columns[1].buf))
assert(vim.wait(10000, function()
	return s.chat.state == "ready" or s.chat.state == "exited"
end))
assert(s.chat.state == "ready", table.concat(s.chat.client.stderr, ""))
local draft = table.concat(vim.api.nvim_buf_get_lines(s.chat:get_prompt_buf(), 0, -1, false), "\n")
assert(draft:find(ticket.metadata.id, 1, true), "assignment was not appended")
assert(
	require("aero.tasks.operations").get_ticket(s.task_binding).state == "todo",
	"assignment submitted automatically"
)
s.chat:send_prompt_buf()
assert(vim.wait(15000, function()
	return require("aero.tasks.operations").get_ticket(s.task_binding).state == "review"
end))
assert(vim.wait(10000, function()
	return s.chat.state == "ready"
end))
assert(
	tasks.read_ticket(board.path, ticket.path).metadata.id == ticket.metadata.id,
	"ACP write bypassed task protection"
)
local read = assert(require("aero.tasks.operations").get_ticket(s.task_binding))
assert(read.body:find("Implemented and verified", 1, true))
-- A loaded conversation must receive the same MCP configuration.
sessions.stop(s)
assert(vim.wait(10000, function()
	return s.chat.state == "exited"
end))
assert(sessions.start(s, vim.api.nvim_get_current_win(), true))
assert(vim.wait(10000, function()
	return s.chat.state == "ready" or s.chat.state == "exited"
end))
assert(s.chat.state == "ready", table.concat(s.chat.client.stderr, ""))
sessions.delete(s)
require("aero.config").options.worktree_tabs = false
vim.api.nvim_set_current_tabpage(board_tab)
require("aero.tasks.agent").work(board.metadata.id, ticket.metadata.id)
local without_tabs = assert(sessions.list(root)[1])
assert(vim.api.nvim_get_current_tabpage() ~= board_tab and not vim.t[board_tab].aero_worktree)
assert(vim.api.nvim_buf_is_valid(view.columns[1].buf))
assert(vim.wait(10000, function()
	return without_tabs.chat.state == "ready" or without_tabs.chat.state == "exited"
end))
assert(without_tabs.chat.state == "ready")
sessions.delete(without_tabs)
require("aero.tasks.bridge").stop()
vim.fn.delete(root, "rf")
print("Task assignment ACP/MCP tests passed (new/load, draft, scoped tools, guarded writes).")
vim.cmd("qa!")
