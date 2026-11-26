-- Read-only access to the shared article library, scoped by dispatch to a conversation.
local M = {}

local function entry(directory, name)
	if type(name) ~= "string" or name:find("[/\\%z\r\n]") or not name:match("^[^%.].*%.mdx?$") then
		return
	end

	local path = vim.fs.joinpath(directory, name)
	local stat = vim.uv.fs_lstat(path)

	if not stat or stat.type ~= "file" then
		return
	end

	return path, stat
end

function M.read(session, name)
	local articles = require("aero.articles")
	local directory = articles.directory()

	if name and name ~= "" then
		local path, stat = entry(directory, name)

		if not path then
			return nil, "article unavailable"
		end

		if stat.size > 1024 * 1024 then
			return nil, "article exceeds the 1 MiB preview limit"
		end

		local ok, lines = pcall(vim.fn.readfile, path)

		if not ok then
			return nil, "article unavailable"
		end

		return { name = name, content = table.concat(lines, "\n") }
	end

	local active = articles.active(session)
	local entries = {}

	if vim.fn.isdirectory(directory) == 1 then
		for filename in vim.fs.dir(directory) do
			if entry(directory, filename) then
				table.insert(entries, { name = filename })
			end
		end
	end

	table.sort(entries, function(a, b)
		return a.name < b.name
	end)
	return { entries = entries, active = active and vim.fs.basename(active) or nil }
end

return M
