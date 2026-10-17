-- Strip JSONC syntax lexically so comment markers inside strings remain literal.
local M = {}

function M.decode(text)
	local output, index, quoted = {}, 1, false
	while index <= #text do
		local char, pair = text:sub(index, index), text:sub(index, index + 1)
		if quoted then
			table.insert(output, char)
			if char == "\\" then
				index = index + 1
				table.insert(output, text:sub(index, index))
			elseif char == '"' then
				quoted = false
			end
		elseif char == '"' then
			quoted = true
			table.insert(output, char)
		elseif pair == "//" then
			local finish = text:find("[\r\n]", index + 2) or (#text + 1)
			table.insert(output, string.rep(" ", finish - index))
			index = finish - 1
		elseif pair == "/*" then
			local finish = text:find("*/", index + 2, true)
			if not finish then error("unterminated block comment") end
			table.insert(output, (text:sub(index, finish + 1):gsub("[^\r\n]", " ")))
			index = finish + 1
		else
			table.insert(output, char)
		end
		index = index + 1
	end
	text = table.concat(output)
	-- A second string-aware pass removes commas only before closing containers.
	output, index, quoted = {}, 1, false
	local previous
	while index <= #text do
		local char = text:sub(index, index)
		if quoted then
			table.insert(output, char)
			if char == "\\" then
				index = index + 1
				table.insert(output, text:sub(index, index))
			elseif char == '"' then
				quoted = false
			end
		elseif char == '"' then
			quoted = true
			table.insert(output, char)
		elseif char == "," and previous and not previous:match("[%[{:,]")
			and text:sub(index + 1):match("^%s*[%]}]") then
			table.insert(output, " ")
		else
			table.insert(output, char)
		end
		if not char:match("%s") then previous = char end
		index = index + 1
	end
	return vim.json.decode(table.concat(output))
end

return M
