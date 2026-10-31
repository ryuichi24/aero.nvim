-- Shared Session info behavior, independent of the optional Knowledge system.
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
require("aero").setup({
	state_file = directory .. "/state.json",
	animation = false,
	start_insert = false,
	agents = { fixture = { type = "acp", cmd = { "python3", "tests/fixtures/acp.py", "save" } } },
})
local sessions = require("aero.session")
local panel = require("aero.panel")
local info = require("aero.session_info")
local options = require("aero.config").options.panel
local session = assert(sessions.create(vim.fn.getcwd(), "fixture", "Info test"))
local transcript = assert(panel.show(session))
api.nvim_set_current_win(transcript)

assert(vim.wait(5000, function()
	return session.chat and session.chat.state == "ready"
end, 10))
assert(not info.win(), "info must be closed by default")

options.info_height_rows = 6
info.toggle()
local win = assert(info.win())
local buf = api.nvim_win_get_buf(win)

assert(api.nvim_win_get_height(win) == 6, "info must open at its configured height")

local text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

assert(text:find("Name: Info test", 1, true))
assert(text:find("Agent: fixture", 1, true))
assert(text:find("Usage", 1, true))
assert(text:find("MCP", 1, true))
assert(not text:find("Knowledge", 1, true))
assert(api.nvim_get_current_win() == transcript)
assert(not vim.wo[transcript].winbar:find("Board:", 1, true))
assert(panel.owns(win))
assert(#api.nvim_buf_get_extmarks(buf, api.nvim_create_namespace("AeroSessionInfo"), 0, -1, {}) > 0)

api.nvim_win_set_cursor(win, { 8, 0 })
session.chat.usage = { context = { used = 100, size = 1000 } }
info.update()

assert(api.nvim_win_get_cursor(win)[1] == 8)
assert(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("100 / 1,000", 1, true))

local original_servers = session.mcp_servers
local install = require("aero.tasks.install")
local original_version = install.version
install.version = function(command)
	return command == "/bin/aero-mcp" and { version = "1.2.3", bridge_protocol = 1 } or nil
end
session.mcp_servers = {
	{
		name = "aero-reading",
		command = "/bin/aero-mcp",
		args = { "serve", "--tools", "reading" },
		env = { { name = "AERO_MCP_CREDENTIAL", value = "private-credential" } },
	},
	{ name = "aero-knowledge", command = "aero-mcp", args = { "serve", "--tools=knowledge" } },
	{ name = "external", command = "external-mcp", args = { "--token", "private-token" } },
}
info.update()
text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

assert(text:find("Server: aero-reading", 1, true))
assert(text:find("Command: /bin/aero-mcp", 1, true))
assert(text:find("Tool sets: reading", 1, true))
assert(text:find("Tool sets: knowledge", 1, true))
assert(text:find("Configured tools (1): aero_reading_list_publish", 1, true))
assert(text:find("Configured tools (1): aero_knowledge", 1, true))
assert(text:find("Version: 1.2.3", 1, true))
assert(text:find("Bridge protocol: 1", 1, true))
assert(text:find("Scope: Worktree: " .. session.worktree, 1, true))
assert(text:find("Server: external", 1, true))
assert(not text:find("private-", 1, true))

install.version = original_version
local mcp = require("aero.mcp_info")
local configured = table.concat(
	mcp.lines({
		worktree = session.worktree,
		mcp_servers = { { name = "aero-tasks", args = { "--tools", "reading,reports,reading" } } },
	}),
	"\n"
)

assert(configured:find("Configured tools (2): aero_create_report, aero_reading_list_publish", 1, true))

configured = table.concat(
	mcp.lines({
		worktree = session.worktree,
		mcp_servers = { { name = "aero-reading", args = { "--tools", "unknown" } } },
	}),
	"\n"
)

assert(configured:find("Configured tools: not reported", 1, true))

local reading_options = require("aero.config").options.reading.agent
local original_reading = vim.deepcopy(reading_options)
reading_options.enabled = true
reading_options.executable = directory .. "/missing-mcp"
local failed = { worktree = session.worktree, key = "failed-mcp" }
local attached, attach_err = require("aero.reading_agent").attach(failed)

assert(not attached and attach_err)
assert(table.concat(mcp.lines(failed), "\n"):find("Attachment error (aero-reading):", 1, true))

reading_options.enabled = false

assert(require("aero.reading_agent").attach(failed))
assert(not table.concat(mcp.lines(failed), "\n"):find("Attachment error", 1, true))

require("aero.config").options.reading.agent = original_reading
mcp.result(session, "aero-reading", nil, { message = "test attachment failure" })
info.update()
text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

assert(text:find("Attachment error (aero-reading): test attachment failure", 1, true))

mcp.result(session, "aero-reading", true)
session.mcp_servers = {}
info.update()
text = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")

assert(text:find("Servers: none configured", 1, true))
assert(not text:find("Server: external", 1, true))
assert(not text:find("Attachment error", 1, true))

session.mcp_servers = original_servers
info.update()

api.nvim_set_current_win(win)
local height = api.nvim_win_get_height(win)
local grow = vim.fn.maparg(require("aero.layout").keys(false).grow, "n", false, true)
grow.callback()

assert(api.nvim_win_get_height(win) > height)
assert(api.nvim_get_current_win() == win)

api.nvim_set_current_win(transcript)

-- Simulate a wider UI while the headless screen remains 80 columns.
local original_width = api.nvim_win_get_width
api.nvim_win_get_width = function(target)
	return target == transcript and 110 or original_width(target)
end
options.info_auto_position = false
info.reflow()

assert(api.nvim_win_get_position(win)[1] < api.nvim_win_get_position(transcript)[1])

options.info_auto_position = true
options.info_position_threshold_columns = 120
info.reflow()

assert(api.nvim_win_get_position(win)[1] < api.nvim_win_get_position(transcript)[1])

options.info_position_threshold_columns = 100
info.reflow()
api.nvim_win_get_width = original_width

assert(api.nvim_win_get_position(win)[2] > api.nvim_win_get_position(transcript)[2])
assert(api.nvim_get_current_win() == transcript)
assert(api.nvim_win_get_cursor(win)[1] == 8)

api.nvim_win_set_width(transcript, 40)
info.reflow()

assert(api.nvim_win_get_position(win)[1] < api.nvim_win_get_position(transcript)[1])
assert(api.nvim_win_get_height(win) == 6, "moving info above the transcript must use its configured height")

info.close()

assert(not info.win())
assert(vim.wo[transcript].winbar:find("Board:", 1, true))

options.info_open_by_default = true
panel.close()

assert(panel.show(session))
assert(info.win(), "info must open with the configured default")

info.close()
panel.shown(session)

assert(not info.win(), "manual dismissal must survive session updates")

sessions.stop(session)
print("Session info tests passed")
