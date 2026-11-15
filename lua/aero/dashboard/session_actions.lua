-- Compatibility adapter for the former dashboard-selection API.
local actions = require("aero.session.actions")
local M = vim.tbl_extend("force", {}, actions)

function M.start(item, agent, on_created, open_session)
	return actions.start(item and item.wt, agent, on_created, open_session)
end

function M.choose(item, label, on_created, open_session, agent_filter)
	return actions.choose(item and item.wt, label, on_created, open_session, agent_filter)
end

return M
