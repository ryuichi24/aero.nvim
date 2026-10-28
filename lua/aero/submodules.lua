-- On-demand checkout discovery. No recursive Git commands or network requests.
local M = {}
local cache, queue, active, generation = {}, {}, 0, 0
local repositories = {}
local parents, entry_keys = {}, {}

local function canonical(path)
	return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

local function pump()
	while active < 2 and #queue > 0 do
		local job = table.remove(queue, 1)
		active = active + 1
		vim.system(job.args, { text = false, timeout = 10000 }, function(result)
			vim.schedule(function()
				active = active - 1

				if job.generation == generation then
					job.done(result)
				end

				pump()
			end)
		end)
	end
end

local function request(key, args, parse, changed)
	if cache[key] then
		return cache[key]
	end

	local entry = { loading = true }
	cache[key] = entry
	table.insert(queue, {
		args = args,
		generation = generation,
		done = function(result)
			entry.loading = false

			if result.code == 0 then
				entry.list = parse(result.stdout or "")
			else
				entry.err = vim.trim(result.stderr or "")
			end

			changed()
		end,
	})
	pump()
	return entry
end

function M.entries(path, changed)
	path = canonical(path)
	local stat = vim.uv.fs_stat(vim.fs.joinpath(path, ".gitmodules"))

	if not stat then
		return { list = {} }
	end

	local key = "modules:" .. path .. ":" .. stat.size .. ":" .. stat.mtime.sec .. ":" .. stat.mtime.nsec

	if entry_keys[path] and entry_keys[path] ~= key then
		cache[entry_keys[path]] = nil
	end

	entry_keys[path] = key
	return request(key, {
		"git",
		"-C",
		path,
		"config",
		"--null",
		"--file",
		".gitmodules",
		"--get-regexp",
		"^submodule\\..*\\.path$",
	}, function(out)
		local entries = {}

		for record in out:gmatch("([^%z]+)%z") do
			local relative = record:match("^[^\n]+\n(.*)$")

			if
				relative
				and not vim.startswith(relative, "/")
				and not relative:match("^%.%./")
				and not relative:match("/%.%./")
			then
				local checkout = vim.fs.normalize(vim.fs.joinpath(path, relative))
				table.insert(entries, { name = relative, path = checkout })

				if entry_keys[path] == key then
					parents[checkout] = path
				end
			end
		end

		table.sort(entries, function(a, b)
			return a.name < b.name
		end)
		return entries
	end, changed)
end

function M.worktrees(path, changed)
	path = canonical(path)
	local identity = request("identity:" .. path, {
		"git",
		"-C",
		path,
		"rev-parse",
		"--path-format=absolute",
		"--git-common-dir",
	}, function(out)
		return { vim.trim(out) }
	end, changed)

	if not identity.list then
		return identity
	end

	local common = vim.uv.fs_realpath(identity.list[1]) or identity.list[1]
	local listed = request(
		"trees:" .. common,
		{ "git", "-C", path, "worktree", "list", "--porcelain", "-z" },
		function(out)
			local trees, current = {}, nil

			for field in out:gmatch("([^%z]+)%z") do
				local key, value = field:match("^(%S+)%s?(.*)$")

				if key == "worktree" then
					current = { path = value }
					table.insert(trees, current)
				elseif current and key == "branch" then
					current.branch = value:gsub("^refs/heads/", "")
				elseif current and key == "HEAD" then
					current.head = value
				elseif current and key == "bare" then
					current.bare = true
				end
			end

			return vim.tbl_filter(function(tree)
				return not tree.bare
			end, trees)
		end,
		changed
	)

	-- Git can report an absorbed submodule's common directory as its main
	-- worktree. Resolve core.worktree through Git before exposing that row.
	for _, tree in ipairs(listed.list or {}) do
		if tree.path == common then
			local main = request("main:" .. common, {
				"git",
				"-C",
				common,
				"rev-parse",
				"--show-toplevel",
			}, function(out)
				return { vim.trim(out) }
			end, changed)

			if not main.list then
				return main
			end

			require("aero.git").correct_main(listed.list, common, main.list[1])
		end
	end

	if listed.list and listed.list[1] then
		local root = require("aero.git").remember_repository(listed.list, path)
		local previous = repositories[common]
		local mounts = previous and previous.mounts or {}
		mounts[path] = true
		repositories[common] =
			{ ws = { root = root, name = vim.fs.basename(root) }, list = listed.list, mounts = mounts }

		if not previous or previous.list ~= listed.list then
			require("aero.events").emit("repositories_changed", {})
		end
	end

	return listed
end

-- Reuse repositories already discovered in the sidebar without recursive scans.
function M.known_repositories()
	return vim.tbl_values(repositories)
end

function M.initialized(path)
	return vim.uv.fs_stat(vim.fs.joinpath(path, ".git")) ~= nil
end

-- Follow known mount relationships only; never recursively scan to reveal a row.
function M.ancestry(path, visited)
	path = canonical(path)
	visited = visited or {}

	if visited[path] then
		return
	end

	visited[path] = true

	for _, repository in pairs(repositories) do
		for _, tree in ipairs(repository.list) do
			if tree.path == path then
				for mount in pairs(repository.mounts) do
					local parent = parents[mount]

					if parent then
						return { worktree = parent, mount = mount, parent = M.ancestry(parent, visited) }
					end
				end
			end
		end
	end
end

function M.invalidate(refresh)
	local previous = repositories
	generation = generation + 1
	cache, queue = {}, {}
	repositories = refresh and previous or {}
	entry_keys = {}
	require("aero.git").invalidate()

	if not refresh then
		return
	end

	for _, repository in pairs(previous) do
		local function reload()
			local entry = M.worktrees(repository.ws.root, reload)

			if not entry.loading then
				require("aero.events").emit("repositories_changed", {})
			end
		end

		reload()
	end
end

return M
