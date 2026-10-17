-- Worktree-bound reference operations for the authenticated companion.
local M = {}
local uv = vim.uv
local policy = require("aero.companion.reference_policy")

function M.entry(worktree, relative)
	if type(relative) ~= "string" or relative == "" or relative:find("[%c]") or relative:sub(1, 1) == "/" then
		return nil, "invalid reference path"
	end
	for component in relative:gmatch("[^/]+") do
		if component == "." or component == ".." then
			return nil, "invalid reference path"
		end
	end
	local root = require("aero.reference").directory(worktree)
	local path = vim.fs.joinpath(root, relative)
	local parent = require("aero.storage").canonical(vim.fs.dirname(path))
	if parent ~= root and not require("aero.storage").inside(parent, root) then
		return nil, "reference path escapes storage"
	end
	local stat = uv.fs_lstat(path)
	if not stat then
		return nil, "reference item unavailable"
	end
	return { path = path, name = vim.fs.basename(path), kind = stat.type }
end

function M.browse(params)
	local path = params.path
	local initial = path == nil or path == ""
	if path == nil or path == "" then
		path = vim.fn.expand(require("aero.config").options.reference_finder.home)
	end
	if type(path) ~= "string" or path:find("[%c]") then
		return nil, "invalid finder path"
	end
	path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	local roots, roots_err = policy.roots()
	if not roots then
		return nil, roots_err
	end
	local permitted, policy_err = policy.allowed(path)
	if not permitted and initial and roots[1] then
		path = roots[1]
		permitted, policy_err = policy.allowed(path)
	end
	if not permitted then
		return nil, policy_err
	end
	local scan, err = uv.fs_scandir(path)
	if not scan then
		return nil, tostring(err)
	end
	local entries = {}
	local limit = policy.options().max_listing_entries
	if limit ~= false and (type(limit) ~= "number" or limit < 1 or limit ~= math.floor(limit)) then
		return nil, "companion.reference_finder.max_listing_entries must be a positive integer or false"
	end
	local count = 0
	while true do
		local name, kind = uv.fs_scandir_next(scan)
		if not name then
			break
		end
		count = count + 1
		if limit and count > limit then
			return nil, "finder directory exceeds companion.reference_finder.max_listing_entries"
		end
		if kind == "file" or kind == "directory" or kind == "link" then
			local entry_path = vim.fs.joinpath(path, name)
			if policy.allowed(entry_path) then
				table.insert(entries, { name = name, path = entry_path, directory = kind == "directory" })
			end
		end
	end
	table.sort(entries, function(a, b)
		if a.directory ~= b.directory then
			return a.directory
		end
		return a.name < b.name
	end)
	local parent = vim.fs.dirname(path) or path
	if not policy.allowed(parent) then
		parent = path
	end
	return { path = path, parent = parent, entries = entries, allow_cut = policy.options().allow_cut, roots = roots }
end

function M.update(params, callback)
	local reference = require("aero.reference")
	if require("aero.companion.reference_transfer").busy(params.worktree) then
		return nil, "a reference transfer is already running for this worktree"
	end
	if params.reference_action == "transfer" then
		if type(params.items) ~= "table" or #params.items == 0 or #params.items > 200 then
			return nil, "select 1-200 reference items"
		end
		for _, item in ipairs(params.items) do
			if
				type(item) ~= "table"
				or type(item.path) ~= "string"
				or item.path:sub(1, 1) ~= "/"
				or item.path:find("[%c]")
				or (item.action ~= "copy" and item.action ~= "cut")
			then
				return nil, "invalid reference transfer item"
			end
			item.done = nil
			if item.action == "cut" and not policy.options().allow_cut then
				return nil, "remote reference cutting is disabled"
			end
			local permitted, err = policy.allowed(item.path)
			if not permitted then
				return nil, err
			end
		end
		return require("aero.companion.reference_transfer").start(
			params.worktree,
			vim.deepcopy(params.items),
			callback,
			params.operation_id
		)
	elseif params.reference_action == "rename" or params.reference_action == "delete" then
		local entry, err = M.entry(params.worktree, params.path)
		if not entry then
			return nil, err
		end
		if params.reference_action == "rename" then
			local renamed
			renamed, err = reference.rename(entry, params.name)
			if not renamed then
				return nil, err
			end
		elseif entry.kind == "directory" then
			if vim.fn.delete(entry.path, "rf") ~= 0 then
				return nil, "could not delete reference folder"
			end
		else
			local ok
			ok, err = uv.fs_unlink(entry.path)
			if not ok then
				return nil, err
			end
		end
		require("aero.events").emit("reference_changed", { worktree = params.worktree })
	else
		return nil, "unknown reference action"
	end
	return { status = "accepted" }
end

return M
