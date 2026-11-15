-- Ordered session tool lifetimes. Modules stay lazy for terminal and history-only sessions.
local M = {}
local attachments = {
	{ module = "aero.reading_agent", name = "reading" },
	{ module = "aero.browser.agent", name = "browser" },
	{ module = "aero.knowledge.agent", name = "knowledge" },
}

--- Prepare tools before launching an ACP backend. A failure prevents later attachments.
--- Previously attached tools remain available for retry; this is not a rollback boundary.
function M.prepare(session, agent, opts)
	opts = opts or {}

	if agent.type ~= "acp" or opts.history_only then
		return true
	end

	if opts.restore_tasks ~= false then
		local restored, err = require("aero.tasks.agent").restore(session)

		if not restored then
			return nil, "cannot reconnect task tools: " .. (type(err) == "table" and err.message or tostring(err))
		end
	end

	for _, attachment in ipairs(attachments) do
		local attached, err = require(attachment.module).attach(session)

		if not attached then
			return nil, "cannot attach " .. attachment.name .. " tools: " .. tostring(err)
		end
	end

	return true
end

--- Release tool bindings only when deleting the session, not when stopping its backend.
function M.detach(session)
	if session.task_transport then
		require("aero.tasks.bridge").unbind(session.task_transport.credential)
	end

	for _, attachment in ipairs(attachments) do
		require(attachment.module).detach(session)
	end
end

return M
