-- Shared source preparation; callers own destination policy and transfer recovery.
local paths = require("aero.storage")
local M = {}

function M.prepare(items)
	local prepared, names = {}, {}

	for _, item in ipairs(items) do
		if not item.done then
			if item.action ~= "copy" and item.action ~= "cut" then
				return nil, "invalid source transfer action"
			end

			local root = paths.canonical(item.path)
			local name = vim.fs.basename(item.path)

			if names[name] then
				return nil, "source item already selected: " .. name
			end

			names[name] = true
			table.insert(prepared, { item = item, root = root, name = name })
		end
	end

	for _, source in ipairs(prepared) do
		for _, other in ipairs(prepared) do
			if source ~= other and (source.root == other.root or paths.inside(other.root, source.root)) then
				return nil, "select a folder or its contents, rather than both: " .. source.item.path
			end
		end
	end

	return prepared
end

function M.destination_inside_source(source, destination)
	return source == "/" or destination == source or paths.inside(destination, source)
end

return M
