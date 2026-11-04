local M = {}

function M.detach(session)
	require("aero.mcp_attachment").detach(session, { name = "aero-browser", transport_field = "browser_transport" })
end

local function attach(session)
	M.detach(session)

	if not require("aero.config").options.browser.agent.enabled then
		return true
	end

	local executable, err = require("aero.tasks.install").resolve()

	if not executable then
		return nil, err
	end

	return require("aero.mcp_attachment").attach(session, {
		name = "aero-browser",
		transport_field = "browser_transport",
		executable = executable,
		tools = "browser",
		binding = { worktree = session.worktree, session_key = session.key, browser_only = true },
	})
end

function M.attach(session)
	return require("aero.mcp_info").result(session, "aero-browser", attach(session))
end

return M
