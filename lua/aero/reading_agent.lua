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

	local transport
	transport, err = require("aero.tasks.bridge").bind({
		worktree = session.worktree,
		session_key = session.key,
		reading_only = true,
	})

	if not transport then
		return nil, err
	end

	session.reading_transport = transport
	session.mcp_servers = vim.tbl_filter(function(server)
		return server.name ~= "aero-reading"
	end, session.mcp_servers or {})
	table.insert(session.mcp_servers, {
		name = "aero-reading",
		command = executable,
		args = { "serve", "--socket", transport.socket, "--tools", "reading" },
		env = { { name = "AERO_MCP_CREDENTIAL", value = transport.credential } },
	})
	return true
end

function M.attach(session)
	return require("aero.mcp_info").result(session, "aero-reading", attach(session))
end

function M.detach(session)
	if session.reading_transport then
		require("aero.tasks.bridge").unbind(session.reading_transport.credential)
		session.reading_transport = nil
	end

	session.mcp_servers = vim.tbl_filter(function(server)
		return server.name ~= "aero-reading"
	end, session.mcp_servers or {})
end

return M
