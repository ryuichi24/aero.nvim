-- Shared transport lifecycle; feature modules own validation and session metadata.
local M = {}

function M.detach(session, options)
	local transport = session[options.transport_field]

	if transport then
		require("aero.tasks.bridge").unbind(transport.credential)
		session[options.transport_field] = nil
	end

	session.mcp_servers = vim.tbl_filter(function(server)
		return server.name ~= options.name
	end, session.mcp_servers or {})
end

function M.attach(session, options)
	local transport, err = require("aero.tasks.bridge").bind(options.binding)

	if not transport then
		return nil, err
	end

	-- Keep the previous credential usable if binding the replacement fails.
	M.detach(session, options)
	session[options.transport_field] = transport
	table.insert(session.mcp_servers, {
		name = options.name,
		command = options.executable,
		args = { "serve", "--socket", transport.socket, "--tools", options.tools },
		env = { { name = "AERO_MCP_CREDENTIAL", value = transport.credential } },
	})
	return true
end

return M
