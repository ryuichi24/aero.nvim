-- Public assignment descriptions shared by editor and companion surfaces.
local M = {}

function M.describe(session)
	local saved = require("aero.store").find_session(session.worktree, session.name)
	local binding = session.task_binding
	local assignment = binding
			and {
				workspace_root = binding.workspace.root,
				board_id = binding.board_id,
				ticket_id = binding.ticket_id,
			}
		or saved and saved.task_assignment
	if type(assignment) ~= "table" then
		return nil
	end
	local result = vim.deepcopy(assignment)
	result.pending = session.task_assignment_pending or session.chat and session.chat.task_pending or false
	local tasks = require("aero.tasks")
	local board, err = tasks.resolve_board({ root = assignment.workspace_root }, assignment.board_id)
	if not board then
		result.error = type(err) == "table" and err.message or tostring(err)
		return result
	end
	result.board_title = board.metadata.title
	if assignment.ticket_id then
		local ticket, ticket_err = tasks.resolve_ticket(board, assignment.ticket_id)
		if ticket then
			result.ticket_title = ticket.metadata.title
			for _, state in ipairs(board.states) do
				for _, entry in ipairs(state.entries) do
					if entry.path == ticket.path then
						result.ticket_state = state.name
					end
				end
			end
		else
			result.error = type(ticket_err) == "table" and ticket_err.message or tostring(ticket_err)
		end
	end
	return result
end

function M.label(session)
	local assignment = M.describe(session)
	if not assignment then
		return "Board: none · Ticket: none"
	end
	return ("Board: %s [%s] · Ticket: %s%s%s")
		:format(
			assignment.board_title or assignment.board_id,
			assignment.board_id,
			assignment.ticket_id
					and ((assignment.ticket_title or assignment.ticket_id) .. " [" .. assignment.ticket_id .. "]")
				or "none (board-only)",
			assignment.ticket_state and (" · " .. assignment.ticket_state) or "",
			assignment.error and " · unavailable" or assignment.pending and " · assigning" or ""
		)
		:gsub("[%c]", " ")
end

return M
