vim.opt.rtp:prepend(vim.fn.getcwd())
local attachment = require("aero.mcp_attachment")
local live, calls = {}, {}
local failure
local sequence = 0
package.loaded["aero.tasks.bridge"] = {
	bind = function(binding)
		table.insert(calls, "bind")

		if failure then
			return nil, failure
		end

		sequence = sequence + 1
		local credential = "credential-" .. sequence
		live[credential] = vim.deepcopy(binding)
		return { socket = "/test/socket", credential = credential }
	end,
	unbind = function(credential)
		table.insert(calls, "unbind:" .. credential)
		live[credential] = nil
	end,
}
local custom = { name = "custom", command = "custom-server" }
local session = { mcp_servers = { custom } }
local tasks = {
	name = "aero-tasks",
	transport_field = "task_transport",
	executable = "/test/aero-mcp",
	tools = "tasks,reports,reading",
	binding = { board_id = "board-1", session_key = "session-1" },
}
local reading = {
	name = "aero-reading",
	transport_field = "reading_transport",
	executable = "/test/aero-mcp",
	tools = "reading",
	binding = { reading_only = true, session_key = "session-1" },
}

assert(attachment.attach(session, tasks))
assert(attachment.attach(session, reading))
assert(session.mcp_servers[1] == custom, "unrelated server was replaced")
assert(#session.mcp_servers == 3)
assert(vim.deep_equal(live[session.task_transport.credential], tasks.binding))

local previous = session.task_transport
local servers = session.mcp_servers
failure = "binding failed"
local ok, err = attachment.attach(session, tasks)

assert(not ok and err == failure)
assert(session.task_transport == previous and live[previous.credential])
assert(session.mcp_servers == servers, "failed replacement changed server configuration")

failure = nil
calls = {}

assert(attachment.attach(session, tasks))
assert(vim.deep_equal(calls, { "bind", "unbind:" .. previous.credential }))
assert(not live[previous.credential])
assert(#session.mcp_servers == 3, "replacement duplicated server configuration")
assert(vim.deep_equal(session.mcp_servers[3], {
	name = tasks.name,
	command = tasks.executable,
	args = { "serve", "--socket", "/test/socket", "--tools", tasks.tools },
	env = { { name = "AERO_MCP_CREDENTIAL", value = session.task_transport.credential } },
}))

local credential = session.task_transport.credential
attachment.detach(session, tasks)
attachment.detach(session, tasks)

assert(not session.task_transport and not live[credential])
assert(#session.mcp_servers == 2 and session.mcp_servers[1] == custom)
assert(live[session.reading_transport.credential], "detach revoked another feature's credential")

-- Assignment staging must not revoke credentials retained for rollback.
local staged = {}

assert(attachment.attach(staged, reading))

attachment.detach(staged, reading)

assert(live[session.reading_transport.credential])

attachment.detach(session, reading)
attachment.detach({}, reading)

assert(vim.tbl_isempty(live), "credential leaked")

print("MCP attachment lifecycle tests passed")
