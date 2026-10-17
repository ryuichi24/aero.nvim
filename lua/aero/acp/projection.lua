-- Explicit transcript-block projection shared by history and companion snapshots.
-- Only protocol/content fields cross the boundary; editor caches are never copied.
local M = {}
local fields = {
	"kind",
	"text",
	"timestamp",
	"image",
	"id",
	"title",
	"status",
	"content",
	"locations",
	"rawInput",
	"rawOutput",
	"tool_kind",
	"entries",
	"turn",
	"meta_kind",
	"options",
	"answer",
}

function M.blocks(blocks, persisted)
	local result = {}
	for _, block in ipairs(blocks) do
		local projected = {}
		for _, field in ipairs(fields) do
			if block[field] ~= nil then
				projected[field] = vim.deepcopy(block[field])
			end
		end
		if persisted and projected.kind == "permission" and not projected.answer then
			projected.answer = "interrupted"
		end
		table.insert(result, projected)
	end
	return result
end

function M.history(chat)
	return {
		type = "acp",
		blocks = M.blocks(chat.blocks, true),
		agent_info = chat.agent_info,
		session_id = chat.session_id or chat.saved_session_id,
		usage = chat.usage,
		draft = chat.draft,
	}
end

return M
