-- Project-relative review hierarchy. File nodes retain their exact Git entry.
local M = {}
local order = { staged = 1, unstaged = 2, untracked = 3, branch = 4 }

function M.status(item)
	if item.kind == "untracked" or item.status == "?" then
		return "Untracked", "AeroReviewAdd"
	end

	local status = item.status:sub(1, 1)

	if status == "A" then
		return "Added", "AeroReviewAdd"
	end

	if status == "D" then
		return "Deleted", "AeroReviewDelete"
	end

	if status == "R" then
		return "Renamed", "AeroReviewChange"
	end

	if status == "C" then
		return "Copied", "AeroReviewAdd"
	end

	if status == "U" then
		return "Conflict", "AeroReviewDelete"
	end

	if status == "T" then
		return "Type changed", "AeroReviewChange"
	end

	return "Modified", "AeroReviewChange"
end

function M.build(items)
	local root = { children = {}, directories = {} }

	for _, item in ipairs(items) do
		local parts = vim.split(item.path, "/", { plain = true })
		local parent, path = root, ""

		for i = 1, #parts - 1 do
			local name = parts[i]
			path = path == "" and name or (path .. "/" .. name)
			local directory = parent.directories[name]

			if not directory then
				directory = {
					kind = "directory",
					key = "directory\0" .. path,
					name = name,
					path = path,
					children = {},
					directories = {},
				}
				parent.directories[name] = directory
				table.insert(parent.children, directory)
			end

			parent = directory
		end

		table.insert(parent.children, {
			kind = "file",
			key = item.kind .. "\0" .. item.path,
			name = parts[#parts],
			path = item.path,
			item = item,
		})
	end

	local function sort(node)
		table.sort(node.children, function(a, b)
			if a.kind ~= b.kind then
				return a.kind == "directory"
			end

			if a.name ~= b.name then
				return a.name < b.name
			end

			if a.kind == "directory" then
				return false
			end

			return (order[a.item.kind] or 5) < (order[b.item.kind] or 5)
		end)

		for _, child in ipairs(node.children) do
			if child.kind == "directory" then
				sort(child)
			end
		end
	end

	sort(root)
	return root
end

function M.render(root, collapsed, icons)
	local lines, rows = {}, {}

	local function walk(node, depth, parent)
		for _, child in ipairs(node.children) do
			local row = #rows + 1
			table.insert(rows, { node = child, parent = parent, depth = depth })
			local prefix = string.rep("  ", depth)
			local name = vim.fn.strtrans(child.name)

			if child.kind == "directory" then
				table.insert(
					lines,
					prefix .. (collapsed[child.path] and icons.collapsed or icons.expanded) .. " " .. name .. "/"
				)

				if not collapsed[child.path] then
					walk(child, depth + 1, row)
				end
			else
				local item = child.item
				local status = M.status(item)
				table.insert(
					lines,
					("%s  [%s] %s [%s]%s"):format(
						prefix,
						status,
						name,
						item.kind,
						item.old_path and (" (from " .. vim.fn.strtrans(item.old_path) .. ")") or ""
					)
				)
			end
		end
	end

	walk(root, 0, nil)
	return lines, rows
end

return M
