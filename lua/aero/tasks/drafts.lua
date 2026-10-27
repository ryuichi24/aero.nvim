-- Retained board-editing registry and draft status, independent of window rendering.
-- Hidden or closed-tab columns remain registered until explicitly discarded.
local api = vim.api
local M = {}
local sessions = {}

function M.sessions()
	return sessions
end

function M.dirty(view)
	for _, column in ipairs(view.columns or {}) do
		if not api.nvim_buf_is_valid(column.buf) or vim.bo[column.buf].modified then
			return true
		end
	end

	return false
end

function M.status(path)
	local view = sessions[require("aero.storage").canonical(path)]
	local status = { dirty = false, stale = false, missing_column = false }

	if not view then
		return status
	end

	status.dirty = M.dirty(view)
	status.stale = require("aero.tasks.storage").read(view.board.path) ~= view.baseline_text

	for _, column in ipairs(view.columns or {}) do
		if not api.nvim_buf_is_valid(column.buf) then
			status.missing_column = true
		end
	end

	return status
end

return M
