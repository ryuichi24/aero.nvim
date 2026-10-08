-- nvim --headless -u NONE -l tests/companion.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	companion = { bind = "100.101.102.103", origin = "http://100.101.102.103:8765", allow_http = true },
	agents = { fixture = { type = "acp", cmd = { "python3", "tests/fixtures/companion_acp.py" } } },
})
local sessions, bridge = require("aero.session"), require("aero.companion")
local config = require("aero.config")
assert(config.defaults.companion.allow_http == false)
assert(config.options.companion.allow_http == true, "setup did not apply the explicit HTTP opt-in")
local socket, settings_file = bridge.start()
local settings = vim.json.decode(table.concat(vim.fn.readfile(settings_file), "\n"))
assert(settings.socket == socket and settings.allow_http == true)
assert(settings.bind == "100.101.102.103" and settings.origin == "http://100.101.102.103:8765")
assert(vim.uv.fs_stat(settings_file).mode % 512 == 384, "exported settings must be private")
assert(select(2, bridge.start()) == settings_file, "repeated start changed settings path")
bridge.stop()
assert(not vim.uv.fs_stat(settings_file) and not vim.uv.fs_stat(socket), "stop did not remove exported settings")
require("aero.store").add_workspace(vim.fn.getcwd())
local forbidden, forbidden_error = bridge.dispatch("nvim_exec_lua", { code = "error('must never execute')" })
assert(not forbidden and forbidden_error == "unknown method")
local s = assert(sessions.create(vim.fn.getcwd(), "fixture"))
assert(require("aero.panel").show(s))
local function wait(fn)
	assert(vim.wait(5000, fn, 10), "timed out")
end
wait(function()
	return s.chat.state == "ready"
end)
local snapshot = bridge.dispatch("snapshot")
assert(snapshot.workspaces[1].root == vim.fn.getcwd())
assert(vim.tbl_contains(
	vim.tbl_map(function(wt)
		return wt.path
	end, snapshot.worktrees),
	vim.fn.getcwd()
))
local generation = snapshot.sessions[1].conversation
local function params(id, extra)
	return vim.tbl_extend("force", { operation_id = id, session = s.key, conversation = generation }, extra or {})
end
local request = params("prompt-0000000001", { text = "permission" })
assert(bridge.dispatch("prompt", request).status == "accepted")
assert(bridge.dispatch("prompt", request).status == "accepted")
assert(s.chat.turn == 1, "retry duplicated prompt")
local result, err = bridge.dispatch("prompt", params(request.operation_id, { text = "different" }))
assert(not result and err:find("different arguments"))
wait(function()
	return s.chat.permission ~= nil
end)
local permission = bridge.dispatch("snapshot").sessions[1].permission
assert(bridge.dispatch("prompt", params("prompt-0000000002", { text = "queued followup" })).status == "queued")
assert(#s.chat.queue == 1)
result, err = bridge.dispatch("permission", params("permission-000001", { permission = "stale", option = "allow" }))
assert(not result and err == "stale permission" and s.chat.permission)
local answer = params("permission-000002", { permission = permission.id, option = "allow" })
assert(bridge.dispatch("permission", answer).status == "accepted")
assert(bridge.dispatch("permission", answer).status == "accepted")
result, err =
	bridge.dispatch("permission", params("permission-000003", { permission = permission.id, option = "allow" }))
assert(not result and err == "stale permission")
wait(function()
	return not s.chat.busy
end)
assert(s.chat.turn == 2 and #s.chat.queue == 0)
assert(bridge.dispatch("prompt", params("prompt-0000000003", { text = "hold" })))
wait(function()
	return s.chat.permission ~= nil
end)
assert(bridge.dispatch("cancel", params("cancel-0000000001")).status == "accepted")
wait(function()
	return not s.chat.busy
end)
assert(not s.chat.permission)
-- Report commands resolve against the selected worktree and retries never create twice.
config.options.reports.directory = dir .. "/reports"
local sent
local original_prompt = s.chat.prompt
s.chat.prompt = function(_, text)
	sent = text
end
local report_request = params("report-0000000001", { text = "/report new investigation\nFocus on startup." })
assert(bridge.dispatch("prompt", report_request).status == "accepted")
assert(sent:find("investigation.md", 1, true) and sent:find("Focus on startup.", 1, true))
assert(bridge.dispatch("prompt", report_request).status == "accepted")
assert(bridge.dispatch("prompt", params("report-0000000002", { text = "/report select investigation.md" })))
result, err = bridge.dispatch("prompt", params("report-0000000003", { text = "/report select missing.md" }))
assert(not result and err == "report unavailable")
result, err = bridge.dispatch("prompt", params("report-0000000004", { text = "/report new ../escape" }))
assert(not result and err:find("directory separators"))
-- Remote selectors and provider commands never open editor-local pickers.
s.chat.config_options = {
	{
		id = "model",
		type = "select",
		category = "model",
		currentValue = "one",
		options = {
			{ value = "one", name = "First" },
			{ value = "two", name = "Second" },
		},
	},
	{
		id = "mode",
		type = "select",
		category = "mode",
		currentValue = "plan",
		options = {
			{ value = "plan", name = "Plan" },
			{ value = "build", name = "Build" },
		},
	},
}
s.chat.commands = { { name = "compact", description = "Compact context" } }
local metadata = bridge.dispatch("snapshot").sessions[1]
assert(metadata.models.choices[2].id == "two" and metadata.modes.current == "plan")
s.chat.usage = { tokens = { totalTokens = 4200, responses = 2 }, context = { used = 1200, size = 10000 } }
local reported_usage = bridge.dispatch("snapshot").sessions[1].usage
assert(reported_usage.tokens.totalTokens == 4200 and reported_usage.context.used == 1200)
reported_usage.context.used = 0
assert(s.chat.usage.context.used == 1200, "companion usage must be an independent snapshot")
assert(metadata.commands[1].name == "compact")
local binding = s.task_binding
s.task_binding = { workspace = { root = s.worktree }, board_id = "fixture" }
assert(bridge.dispatch("prompt", params("command-00000001", { text = "/model Second" })))
assert(sent == "/model two", "assignment prefix broke model command")
assert(bridge.dispatch("prompt", params("command-00000002", { text = "/mode build" })))
assert(sent == "/mode build")
assert(bridge.dispatch("prompt", params("command-00000003", { text = "/compact keep notes" })))
assert(sent == "/compact keep notes", "provider command was rewritten")
result, err = bridge.dispatch("prompt", params("command-00000004", { text = "/model" }))
assert(not result and err:find("choose an available"))
result, err = bridge.dispatch("prompt", params("command-00000005", { text = "/mode missing" }))
assert(not result and err:find("unknown or ambiguous"))
result, err = bridge.dispatch("prompt", params("command-00000006", { text = "/unknown" }))
assert(not result and err:find("unknown slash command"))
local servers = s.mcp_servers
s.mcp_servers = { { name = "fixture" } }
assert(bridge.dispatch("prompt", params("command-00000007", { text = "/new-ticket Investigate startup" })))
assert(sent:find("aero_create_ticket", 1, true) and sent:find("Investigate startup", 1, true))
s.task_binding, s.mcp_servers = binding, servers
result, err = bridge.dispatch("prompt", params("command-00000008", { text = "/new-ticket" }))
assert(not result and err:find("Assign a board"))
config.options.exports.location = "data"
local exported = bridge.dispatch("prompt", params("command-00000009", { text = "/export" }))
assert(exported.status == "accepted" and exported.message:find("Exported log:", 1, true))
assert(bridge.dispatch("prompt", params("command-00000009", { text = "/export" })).message == exported.message)
local export_path = exported.message:sub(#"Exported log: " + 1)
assert(vim.uv.fs_stat(export_path))
vim.fn.delete(export_path)
assert(bridge.dispatch("prompt", params("command-00000010", { text = "/cancel" })).status == "accepted")
s.chat.prompt = original_prompt
-- Replacement chats and in-place ACP conversation changes both invalidate action targets.
local old = s.chat
s.chat = setmetatable(vim.tbl_extend("force", {}, old), getmetatable(old))
result, err = bridge.dispatch("prompt", params("prompt-0000000004", { text = "wrong target" }))
assert(not result and err == "stale conversation")
s.chat = old
old.session_id = "replacement-acp-id"
result, err = bridge.dispatch("cancel", params("cancel-0000000002"))
assert(not result and err == "stale conversation")
old.session_id = "companion-conversation"
old:stop()
wait(function()
	return old.state == "exited"
end)
local turns = old.turn
assert(bridge.dispatch("snapshot").sessions[1].status == "exited")
assert(old.turn == turns and old.state == "exited", "read restarted agent")
bridge.stop()
vim.fn.delete(dir, "rf")
print("companion: ok")
vim.cmd("qa!")
