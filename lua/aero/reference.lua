-- Per-worktree reference material and filesystem transfers for the reference finder.
local M = {}
local uv = vim.uv
local storage = require("aero.storage")
local transfers = require("aero.file_transfer")

function M.directory(worktree, ws)
	worktree = storage.canonical(worktree)
	local setting = require("aero.config").options.reference_finder.directory

	if setting == "data" then
		local root = storage.canonical(ws and ws.root or require("aero.git").main_root(worktree) or worktree)
		local base = vim.fs.joinpath(
			vim.fn.stdpath("data"),
			"Aero",
			"workspaces",
			storage.folder(root),
			storage.folder(worktree)
		)
		local directory = vim.fs.joinpath(base, "references")
		local legacy = vim.fs.joinpath(base, "context")

		-- Reuse existing storage without moving files or invalidating saved prompts.
		if not uv.fs_stat(directory) and uv.fs_stat(legacy) then
			return legacy
		end

		return directory
	end

	if type(setting) == "function" then
		setting = setting(worktree)
	end

	assert(type(setting) == "string" and setting ~= "", "reference_finder.directory must resolve to a path")
	local path = vim.fn.expand(setting)
	return storage.canonical(vim.startswith(path, "/") and path or vim.fs.joinpath(worktree, path))
end

function M.list(worktree)
	local directory = M.directory(worktree)
	local scan, err, code = uv.fs_scandir(directory)

	if not scan then
		return {}, code ~= "ENOENT" and err or nil
	end

	local items = {}
	while true do
		local name, kind = uv.fs_scandir_next(scan)

		if not name then
			break
		end

		table.insert(items, { name = name, path = vim.fs.joinpath(directory, name), kind = kind })
	end
	table.sort(items, function(a, b)
		return a.name < b.name
	end)
	return items
end

local function copy(source, destination)
	local stat, err = uv.fs_lstat(source)

	if not stat then
		return nil, err
	end

	if stat.type == "link" then
		local link, link_err = uv.fs_readlink(source)

		if not link then
			return nil, link_err
		end

		return uv.fs_symlink(link, destination)
	elseif stat.type == "file" then
		return uv.fs_copyfile(source, destination, { excl = true })
	elseif stat.type ~= "directory" then
		return nil, "unsupported file type: " .. source
	end

	local ok, mkdir_err = uv.fs_mkdir(destination, stat.mode)

	if not ok then
		return nil, mkdir_err
	end

	local scan, scan_err = uv.fs_scandir(source)

	if not scan then
		return nil, scan_err
	end

	while true do
		local name = uv.fs_scandir_next(scan)

		if not name then
			break
		end

		local copied, copy_err = copy(vim.fs.joinpath(source, name), vim.fs.joinpath(destination, name))

		if not copied then
			return nil, copy_err
		end
	end
	return true
end

-- Preflight the whole batch before touching sources; never overwrite existing material.
function M.transfer(worktree, items)
	local directory = M.directory(worktree)
	local prepared, prepare_err = transfers.prepare(items)

	if not prepared then
		return nil, prepare_err
	end

	for _, source in ipairs(prepared) do
		local item, name = source.item, source.name

		if uv.fs_lstat(vim.fs.joinpath(directory, name)) then
			return nil, "reference item already exists: " .. name
		end

		if not uv.fs_lstat(item.path) then
			return nil, "source no longer exists: " .. item.path
		end

		if transfers.destination_inside_source(source.root, directory) then
			return nil, "reference destination is inside source: " .. item.path
		end
	end

	vim.fn.mkdir(directory, "p")

	for _, item in ipairs(items) do
		if not item.done then
			local destination = vim.fs.joinpath(directory, vim.fs.basename(item.path))
			local ok, err

			if item.action == "cut" then
				ok, err = uv.fs_rename(item.path, destination)
			end

			if not ok then
				ok, err = copy(item.path, destination)

				if not ok then
					vim.fn.delete(destination, "rf")
					return nil, tostring(err)
				end

				if item.action == "cut" and vim.fn.delete(item.path, "rf") ~= 0 then
					vim.fn.delete(destination, "rf")
					return nil, "could not remove source: " .. item.path
				end
			end

			item.done = true
			require("aero.events").emit("reference_changed", { worktree = worktree })
		end
	end

	return true
end

function M.rename(entry, name)
	if type(name) ~= "string" then
		return nil, "a reference item name is required"
	end

	name = vim.trim(name)

	if name == "" or name == "." or name == ".." or name:find("[/\\%c]") then
		return nil, "use a reference item name without directory separators or control characters"
	end

	local destination = vim.fs.joinpath(vim.fs.dirname(entry.path), name)

	if destination == entry.path then
		return vim.deepcopy(entry)
	end

	if uv.fs_lstat(destination) then
		return nil, "reference item already exists: " .. name
	end

	local ok, err = uv.fs_rename(entry.path, destination)

	if not ok then
		return nil, tostring(err)
	end

	-- Keep editor buffers attached to renamed files, including files inside a folder.
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) then
			local path = vim.api.nvim_buf_get_name(buf)

			if path == entry.path or vim.startswith(path, entry.path .. "/") then
				pcall(vim.api.nvim_buf_set_name, buf, destination .. path:sub(#entry.path + 1))
			end
		end
	end

	return { name = name, path = destination, kind = entry.kind }
end

function M.open(worktree)
	if not worktree then
		local s = require("aero.session_target").resolve("viewed")
		worktree = require("aero.dashboard").selected_worktree()
			or s and s.worktree
			or vim.t.aero_worktree
			or vim.fs.root(vim.fn.getcwd(), ".git")
			or vim.fn.getcwd()
	end

	return require("aero.reference_finder").open(worktree)
end

function M.pick(s)
	local items, err = M.list(s.worktree)

	if err then
		return vim.notify("Aero: " .. err, vim.log.levels.WARN)
	end

	table.insert(items, 1, { name = "Add reference +", finder = true })
	require("aero.picker").open({
		title = "references",
		items = function()
			return items
		end,
		label = function(item)
			return item.name .. (item.kind == "directory" and "/" or "")
		end,
		search = function(item)
			return item.name
		end,
		select = function(item)
			if item.finder then
				return M.open(s.worktree)
			end

			if not uv.fs_lstat(item.path) then
				return vim.notify("Aero: reference item no longer exists", vim.log.levels.WARN)
			end

			if not vim.tbl_contains(require("aero.session").all(), s) then
				return
			end

			require("aero.compose").append(
				s,
				"Read this reference "
					.. (item.kind == "directory" and "folder" or "file")
					.. ": "
					.. vim.json.encode(item.path)
			)
		end,
	})
end

return M
