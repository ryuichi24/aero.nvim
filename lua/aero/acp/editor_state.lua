-- Presentation state is explicitly separate from conversation/protocol fields.
local M = {}

---@return aero.acp.EditorState
function M.get(chat)
	chat.editor = chat.editor or {}
	return chat.editor
end

return M
