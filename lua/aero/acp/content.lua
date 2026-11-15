-- Conversation content mutation without editor reveal state or persistence effects.
local M = {}

local function text(content)
	if type(content) ~= "table" then
		return ""
	end

	if content.type == "text" then
		return content.text or ""
	elseif content.type == "resource_link" then
		return ("[%s](%s)"):format(content.name or content.uri, content.uri or "")
	elseif content.type == "resource" and content.resource then
		return content.resource.text or ("[%s]"):format(content.resource.uri or "resource")
	elseif content.type == "image" then
		return "[image]"
	end

	return ""
end

--- Return editor reveal work separately from the fully recorded content.
function M.append(chat, kind, value)
	local block = chat.blocks[#chat.blocks]

	if block and block.kind == kind and not block.image then
		block.text = block.text .. value
	else
		block = { kind = kind, text = value, timestamp = not chat.replaying and os.time() or nil }
		table.insert(chat.blocks, block)
	end

	if (kind == "agent" or kind == "thought") and not chat.replaying then
		return { block = block, initial_bytes = #block.text - #value }
	end
end

function M.append_content(chat, kind, content)
	if type(content) == "table" and content.type == "image" then
		table.insert(chat.blocks, {
			kind = kind,
			text = "[image]",
			image = vim.deepcopy(content),
			timestamp = not chat.replaying and os.time() or nil,
		})
	else
		return M.append(chat, kind, text(content))
	end
end

return M
