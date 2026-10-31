local M = {}

local function attach(session)
	M.detach(session)
	local options = require("aero.config").options.reading.agent

	if not options.enabled then
		return true
	end

	local executable, err = require("aero.tasks.install").resolve(options.executable)

	if not executable then
		return nil, err
	end

	return require("aero.mcp_attachment").attach(session, {
		name = "aero-reading",
		transport_field = "reading_transport",
		executable = executable,
		tools = "reading",
		binding = { worktree = session.worktree, session_key = session.key, reading_only = true },
	})
end

function M.attach(session)
	return require("aero.mcp_info").result(session, "aero-reading", attach(session))
end

function M.detach(session)
	require("aero.mcp_attachment").detach(session, { name = "aero-reading", transport_field = "reading_transport" })
end

return M
