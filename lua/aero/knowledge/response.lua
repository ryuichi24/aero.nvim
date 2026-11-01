-- Agent-facing text windows are character-bounded; stored evidence stays intact.
local M = {}

function M.window(text, offset, size)
	local total = vim.fn.strchars(text)
	offset = math.max(0, math.floor(tonumber(offset) or 0))
	assert(offset <= total, "text offset is outside the evidence")
	local body = vim.fn.strcharpart(text, offset, size)
	local next_offset = offset + vim.fn.strchars(body)
	return body, next_offset < total and next_offset or nil, total
end

function M.search(result, query)
	for _, hit in ipairs(result.results) do
		local start = 1

		for term in query:lower():gmatch("%S+") do
			local found = hit.text:lower():find(term, 1, true)

			if found then
				start = found
				break
			end
		end

		local offset = math.max(0, vim.fn.strchars(hit.text:sub(1, start - 1)) - 120)
		local text, next_offset, total = M.window(hit.text, offset, 600)
		hit.text, hit.offset = text, offset
		hit.total_chars, hit.truncated = total, offset > 0 or next_offset ~= nil
		hit.citations = nil
	end

	result.incomplete_count = #result.incomplete_sources
	result.warning_count = #result.warning_sources
	while #result.incomplete_sources > 5 do
		table.remove(result.incomplete_sources)
	end
	while #result.warning_sources > 5 do
		table.remove(result.warning_sources)
	end
	return result
end

function M.read(result, offset)
	local budget = 12000
	local chunks = {}

	for _, chunk in ipairs(result.chunks) do
		local text, next_offset, total = M.window(chunk.text, offset, budget)
		chunk.text, chunk.offset, chunk.total_chars = text, offset or 0, total
		chunks[#chunks + 1] = chunk
		budget = budget - vim.fn.strchars(text)

		if next_offset then
			result.next_chunk, result.next_offset = chunk.chunk, next_offset
			break
		elseif budget == 0 then
			result.next_chunk = chunk.chunk < result.total_chunks and chunk.chunk + 1 or nil
			break
		end

		offset = 0
	end

	result.chunks = chunks

	if not result.next_chunk then
		local last = chunks[#chunks].chunk
		result.next_chunk = last < result.total_chunks and last + 1 or nil
	end

	return result
end

return M
