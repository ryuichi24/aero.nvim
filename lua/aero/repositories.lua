-- Registered entry points and already discovered repositories share one projection.
-- Enumeration never recursively discovers submodules or fetches remotes.
local M = {}

local function canonical(path)
	return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

function M.list(load, all)
	local result, errors, seen, roots = {}, {}, {}, {}
	load = load or function(ws)
		return require("aero.git").list(ws.root)
	end

	local function append(ws, list)
		local root = canonical(ws.root)

		if roots[root] then
			return
		end

		roots[root] = true
		local unique = {}

		for _, tree in ipairs(list or {}) do
			local path = canonical(tree.path)

			if not seen[path] then
				seen[path] = true
				table.insert(unique, tree)
			end
		end

		table.insert(result, { ws = ws, list = unique })
	end

	for _, ws in ipairs(require("aero.scenes").workspaces(all)) do
		local list, err = load(ws)

		if not list and err then
			table.insert(errors, ws.name .. ": " .. err)
		end

		append(ws, list)
	end

	for _, repository in ipairs(require("aero.submodules").known_repositories()) do
		local tree = repository.list and repository.list[1]

		if all or tree and require("aero.scenes").contains({ worktree = tree.path }) then
			append(repository.ws, repository.list)
		end
	end

	return result, errors
end

function M.find(root)
	local registered = require("aero.store").find_workspace(root)

	if registered then
		return registered
	end

	for _, repository in ipairs(require("aero.submodules").known_repositories()) do
		if canonical(repository.ws.root) == canonical(root) then
			return repository.ws
		end
	end
end

return M
