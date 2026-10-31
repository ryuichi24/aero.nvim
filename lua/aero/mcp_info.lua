-- Configured MCP metadata; no discovery or connection-health claims.
local M = {}
local tools_by_set = {
	tasks = {
		"aero_list_boards",
		"aero_get_board",
		"aero_get_ticket",
		"aero_create_ticket",
		"aero_move_ticket",
		"aero_update_ticket_body",
		"aero_update_ticket_metadata",
	},
	reports = { "aero_create_report" },
	reading = { "aero_reading_list_publish" },
	knowledge = { "aero_knowledge" },
}
local defaults = {
	["aero-tasks"] = "tasks,reports,reading",
	["aero-reading"] = "reading",
	["aero-knowledge"] = "knowledge",
}

function M.result(session, name, ok, err)
	session.mcp_errors = session.mcp_errors or {}
	session.mcp_errors[name] = not ok and (type(err) == "table" and err.message or tostring(err)) or nil
	return ok, err
end

local function selection(server)
	local sets = defaults[server.name]

	if not sets then
		return
	end

	local args = server.args or {}

	for index, arg in ipairs(args) do
		if arg == "--tools" then
			sets = args[index + 1]
		elseif arg:match("^%-%-tools=") then
			sets = arg:sub(9)
		elseif arg == "--reading-only" then
			sets = "reading"
		elseif arg == "--knowledge-only" then
			sets = "knowledge"
		end
	end

	return sets
end

local function scope(session, name)
	if name == "aero-reading" then
		return "Worktree: " .. session.worktree
	elseif name == "aero-tasks" then
		local binding = session.task_binding

		if binding then
			return "Workspace: " .. binding.workspace.root .. " · " .. require("aero.tasks.status").label(session)
		end
	elseif name == "aero-knowledge" then
		return require("aero.knowledge.agent").label(session)
	end
end

function M.lines(session)
	local lines = {}
	local servers = session.mcp_servers or {}

	if #servers == 0 then
		table.insert(lines, "Servers: none configured")
	end

	for _, server in ipairs(servers) do
		table.insert(lines, "Server: " .. (server.name or "unnamed"))

		if server.command then
			table.insert(lines, "  Command: " .. server.command)
		end

		local sets = selection(server)

		if sets then
			table.insert(lines, "  Tool sets: " .. sets)
			local names, seen = {}, {}
			local known = true

			for _, set in ipairs(vim.split(sets, ",", { plain = true })) do
				local tools = tools_by_set[vim.trim(set)]
				known = known and tools ~= nil

				for _, name in ipairs(tools or {}) do
					if not seen[name] then
						table.insert(names, name)
						seen[name] = true
					end
				end
			end

			if known then
				table.sort(names)
				table.insert(lines, "  Configured tools (" .. #names .. "): " .. table.concat(names, ", "))
			else
				table.insert(lines, "  Configured tools: not reported")
			end

			local version = require("aero.tasks.install").version(server.command)
			table.insert(lines, "  Version: " .. (version and tostring(version.version) or "not reported"))

			if version then
				table.insert(lines, "  Bridge protocol: " .. tostring(version.bridge_protocol))

				if version.knowledge_protocol and server.name == "aero-knowledge" then
					table.insert(lines, "  Knowledge protocol: " .. tostring(version.knowledge_protocol))
				end
			end

			local description = scope(session, server.name)

			if description then
				table.insert(lines, "  Scope: " .. description)
			end
		end
	end

	local errors = session.mcp_errors or {}
	local names = vim.tbl_keys(errors)
	table.sort(names)

	for _, name in ipairs(names) do
		table.insert(lines, "Attachment error (" .. name .. "): " .. errors[name]:gsub("[%c]", " "))
	end

	return lines
end

return M
