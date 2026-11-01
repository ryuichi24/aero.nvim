local M = {}

function M.similarity(a, b)
	if type(a) ~= "table" or type(b) ~= "table" or #a ~= #b then
		return 0
	end

	local dot, left, right = 0, 0, 0

	for index, value in ipairs(a) do
		if type(value) ~= "number" or type(b[index]) ~= "number" then
			return 0
		end

		dot, left, right = dot + value * b[index], left + value * value, right + b[index] * b[index]
	end

	return left > 0 and right > 0 and dot / math.sqrt(left * right) or 0
end

function M.query(text, callback)
	local command = require("aero.config").options.knowledge.embedding_command

	if #command == 0 then
		callback(nil, "No embedding adapter configured; using keyword search")
		return
	end

	local ok, process = pcall(
		vim.system,
		command,
		{ text = true, stdin = vim.json.encode({ texts = { text } }), timeout = 30000 },
		function(result)
			vim.schedule(function()
				local decoded, data = pcall(vim.json.decode, result.stdout or "")

				if
					result.code ~= 0
					or not decoded
					or type(data) ~= "table"
					or type(data.model) ~= "string"
					or type(data.vectors) ~= "table"
					or type(data.vectors[1]) ~= "table"
				then
					callback(nil, "Embedding query failed; using keyword search")
				else
					callback({ model = data.model, vector = data.vectors[1] })
				end
			end)
		end
	)

	if not ok then
		callback(nil, tostring(process))
	end
end

return M
