-- Editor-only streaming progress. Weak keys release state with its chat/block;
-- conversation records retain complete text and never carry reveal metadata.
local M = {}
local queues = setmetatable({}, { __mode = "k" })
local progress = setmetatable({}, { __mode = "k" })

function M.track(chat, block, initial_bytes)
	if progress[block] ~= nil then
		return
	end

	progress[block] = initial_bytes
	queues[chat] = queues[chat] or {}
	table.insert(queues[chat], block)
end

function M.text(block)
	local shown = progress[block]
	return shown and block.text:sub(1, shown) or block.text
end

function M.advance(chat, instant)
	local left = {}

	for _, block in ipairs(queues[chat] or {}) do
		local text, shown = block.text, progress[block]
		local revealed = instant and #text or math.min(#text, shown + math.max(3, math.ceil((#text - shown) / 8)))

		-- Reveal whole UTF-8 characters while catching up proportionally to backlog.
		while revealed < #text and text:byte(revealed + 1) >= 0x80 and text:byte(revealed + 1) < 0xC0 do
			revealed = revealed + 1
		end

		if revealed >= #text then
			progress[block] = nil
		else
			progress[block] = revealed
			table.insert(left, block)
		end
	end

	queues[chat] = #left > 0 and left or nil
	return #left > 0
end

return M
