-- Public setup paths -> resolved runtime paths. Runtime consumers deliberately
-- use a compiled configuration so UI organization does not leak into features.
local M = {}
local groups = {
	sessions = {
		default_agent = "default_agent",
		prompt_name = "prompt_session_name",
		start_insert = "start_insert",
		idle_ms = "idle_ms",
		notify_idle = "notify_idle",
	},
	storage = { sessions = "persist_sessions", buffers = "persist_buffers", state_file = "state_file" },
	worktrees = { path = "worktree_path", tabs = "worktree_tabs" },
	ui = {
		dashboard = "dashboard",
		panel = "panel",
		terminal = "terminal",
		layout = "layout",
		input = "input",
		picker = "picker",
		icons = "icons",
		animation = "animation",
		fullscreen_key = "fullscreen_key",
		quote_key = "quote_key",
		resize = "resize",
		resize_keys = "resize_keys",
	},
}
local chat = {
	permissions = { auto_yes = "auto_yes" },
	transcript = {
		max_tool_lines = "max_tool_lines",
		decorations = "decorations",
		collapsed = "collapsed",
		image_previews = "image_previews",
		show_usage = "show_usage",
	},
	prompt = { height = "prompt_height", tab_completion = "tab_completion", resize_keys = "resize_keys" },
	todos = { enabled = "todo_notifications", timeout = "todo_notification_timeout" },
}

local function table_option(value, path)
	assert(type(value) == "table", "aero.setup: " .. path .. " must be a table")
	return value
end

local function reject_feature_executable(options, path)
	if type(options) == "table" then
		for _, name in ipairs({ "executable", "mcp_executable" }) do
			assert(options[name] == nil, "aero.setup: " .. path .. "." .. name .. " was replaced by mcp.executable")
		end
	end
end

-- Legacy setup keys are accepted at this boundary; grouped keys take precedence.
-- Copy first: normalization and later runtime mutation must never edit user tables.
function M.runtime(opts)
	local result = vim.deepcopy(opts or {})
	table_option(result, "options")

	for group, fields in pairs(groups) do
		local values = result[group]
		result[group] = nil

		if values ~= nil then
			table_option(values, group)

			for name, value in pairs(values) do
				local field = fields[name]
				assert(field, "aero.setup: unknown option " .. group .. "." .. name)
				result[field] = value
			end
		end
	end

	if type(result.dashboard) == "table" and result.dashboard.keymaps ~= nil then
		result.keymaps = result.dashboard.keymaps
		result.dashboard.keymaps = nil
	end

	local values = result.chat
	result.chat = nil

	if values ~= nil then
		table_option(values, "chat")
		result.acp = result.acp or {}
		table_option(result.acp, "acp")

		for group, settings in pairs(values) do
			local fields = chat[group]
			assert(fields, "aero.setup: unknown option chat." .. group)
			table_option(settings, "chat." .. group)

			for name, value in pairs(settings) do
				if name == "line_numbers" and (group == "transcript" or group == "prompt") then
					result.acp.line_numbers = result.acp.line_numbers or {}
					result.acp.line_numbers[group] = value
				else
					local field = fields[name]
					assert(field, "aero.setup: unknown option chat." .. group .. "." .. name)
					result.acp[field] = value
				end
			end
		end
	end

	if result.mcp ~= nil then
		table_option(result.mcp, "mcp")

		for name, value in pairs(result.mcp) do
			assert(name == "executable", "aero.setup: unknown option mcp." .. name)
			assert(value == false or type(value) == "string", "aero.setup: mcp.executable must be a path or false")
		end
	end

	reject_feature_executable(result.knowledge, "knowledge")
	reject_feature_executable(type(result.reading) == "table" and result.reading.agent, "reading.agent")
	reject_feature_executable(type(result.tasks) == "table" and result.tasks.agent, "tasks.agent")
	return result
end

-- Maps merge recursively. Lists (including empty overrides) replace atomically.
function M.merge(default, override)
	if type(default) ~= "table" or type(override) ~= "table" then
		return vim.deepcopy(override)
	end

	if
		vim.islist(default) and not vim.tbl_isempty(default)
		or not vim.tbl_isempty(override) and vim.islist(override)
	then
		return vim.deepcopy(override)
	end

	local result = vim.deepcopy(default)

	for key, value in pairs(override) do
		result[key] = M.merge(default[key], value)
	end

	return result
end

return M
