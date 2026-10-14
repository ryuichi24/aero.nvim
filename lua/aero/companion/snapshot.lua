-- Companion wire projection. Identity registries are supplied by the host owner;
-- transcript data is projected explicitly rather than exposing editor caches.
local M = {}

function M.describe(session, boards, identity, identities, permissions, conversation_ids)
	local chat = session.chat
	local result = {
		id = session.key,
		name = session.name,
		agent = session.agent,
		worktree = session.worktree,
		status = chat and chat.state == "starting" and "starting" or require("aero.session").status(session),
		target = identity(session, identities),
		assignment = require("aero.tasks.status").describe(session, boards),
	}
	if chat then
		local conversation = chat.session_id or chat.saved_session_id or false
		if conversation_ids[chat] ~= conversation then
			identities[chat] = nil
			conversation_ids[chat] = conversation
		end
		result.conversation = identity(chat, identities)
		result.acp_session_id = chat.session_id or chat.saved_session_id
		result.activity = chat:activity()
		result.blocks = require("aero.acp.projection").blocks(chat.blocks, false)
		result.queue, result.usage = vim.deepcopy(chat.queue), vim.deepcopy(chat.usage)
		result.commands = vim.deepcopy(chat.commands or {})
		result.models, result.modes = require("aero.acp.models").options(chat), require("aero.acp.modes").options(chat)
		if chat.permission then
			result.permission = {
				id = identity(chat.permission, permissions),
				title = chat.permission.block.title,
				options = chat.permission.block.options,
			}
		end
	end
	return result
end

function M.build(epoch, worktrees, sessions, describe, conversation_identity)
	local config = require("aero.config").options
	local result = {
		epoch = epoch,
		companion = {
			ui = {
				source_collapsed_by_default = config.companion.ui.source_collapsed_by_default,
				todo_notifications = config.acp.todo_notifications,
				todo_notification_timeout = config.acp.todo_notification_timeout,
			},
		},
		agents = {},
		workspaces = require("aero.store").data.workspaces,
		worktrees = worktrees,
		sessions = {},
		inbox = {},
		boards = {},
	}
	for _, tree in ipairs(worktrees) do
		tree.target = require("aero.companion_lifecycle").target(epoch, tree)
		tree.reports_directory =
			require("aero.reports").directory(tree.path, tree.workspace and { root = tree.workspace })
	end
	for id, agent in pairs(config.agents) do
		if agent.type == "acp" then
			table.insert(result.agents, id)
		end
	end
	table.sort(result.agents)
	local boards = {}
	for _, workspace in ipairs(result.workspaces) do
		boards[workspace.root] = require("aero.tasks").list(workspace)
		for _, board in ipairs(boards[workspace.root]) do
			if board.valid then
				table.insert(
					result.boards,
					{ workspace = workspace.root, id = board.metadata.id, title = board.metadata.title }
				)
			end
		end
	end
	for _, session in ipairs(sessions) do
		local agent = config.agents[session.agent]
		if session.chat or agent and agent.type == "acp" then
			table.insert(result.sessions, describe(session, boards))
		end
	end
	for _, event in ipairs(require("aero.inbox").items()) do
		table.insert(
			result.inbox,
			{
				id = event.key,
				session = event.session.key,
				conversation = conversation_identity(event.chat),
				kind = event.kind,
				text = event.text,
				workspace = event.workspace,
				ticket = event.ticket,
			}
		)
	end
	return result
end

return M
