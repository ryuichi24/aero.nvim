-- Finder batches become managed sources before any cut removes original material.
local store = require("aero.knowledge.store")
local paths = require("aero.storage")
local transfers = require("aero.file_transfer")
local uv = vim.uv
local M = {}

local function scan(path, relative, entries, files)
	local stat = assert(uv.fs_lstat(path), "source no longer exists: " .. path)
	assert(
		stat.type == "file" or stat.type == "directory",
		"select regular files or folders; unsupported source: " .. path
	)
	local entry = { path = path, relative_path = relative, stat = stat }
	entries[path] = entry

	if stat.type == "file" then
		table.insert(files, entry)
		return
	end

	local directory = assert(uv.fs_scandir(path))
	while true do
		local name = uv.fs_scandir_next(directory)

		if not name then
			break
		end

		scan(vim.fs.joinpath(path, name), relative .. "/" .. name, entries, files)
	end
end

local function preflight(space, items, target)
	local plans, existing = {}, {}
	local prefix = target.directory and (target.directory .. "/") or ""

	if target.folder_id then
		store.find(space.folders, target.folder_id)
	end

	local prepared, err = transfers.prepare(items)
	assert(prepared, err)

	for _, source in ipairs(space.sources) do
		if source.folder_id == target.folder_id then
			local relative = source.relative_path or source.name

			if relative:sub(1, #prefix) == prefix then
				existing[relative:sub(#prefix + 1):match("^[^/]+") or source.name] = true
			end
		end
	end

	for _, selected in ipairs(prepared) do
		local item = selected.item

		if not item.done then
			local root = selected.root
			local name = prefix .. vim.fs.basename(root)
			local previous = item.knowledge_import

			if previous then
				assert(previous.space_id == space.id and previous.root == root, "source import target changed")
				assert(previous.name == name and previous.folder_id == target.folder_id, "source import target changed")

				for _, file in ipairs(previous.files) do
					store.find(space.sources, file.source.id)
				end

				table.insert(plans, {
					item = item,
					space_id = space.id,
					root = root,
					name = previous.name,
					entries = previous.entries,
					files = previous.files,
					imported = true,
				})
			else
				assert(not existing[vim.fs.basename(root)], "source item already exists: " .. name)
				assert(
					not transfers.destination_inside_source(root, store.directory())
						and not paths.inside(root, store.directory()),
					"knowledge destination is inside source or source is managed knowledge: " .. root
				)
				local original = assert(uv.fs_lstat(item.path), "source no longer exists: " .. item.path)
				assert(original.type ~= "link", "select regular files or folders rather than symbolic links")
				table.insert(
					plans,
					{ item = item, space_id = space.id, root = root, name = name, entries = {}, files = {} }
				)
			end
		end
	end

	for _, plan in ipairs(plans) do
		if not plan.imported then
			scan(plan.root, plan.name, plan.entries, plan.files)
			assert(#plan.files > 0, "folder contains no source files: " .. plan.root)
			table.sort(plan.files, function(a, b)
				return a.path < b.path
			end)
		end
	end

	return plans
end

local function verify_cut(plan)
	if not uv.fs_lstat(plan.root) then
		return
	end

	local current = {}
	scan(plan.root, plan.name, current, {})

	for path, entry in pairs(current) do
		local old = plan.entries[path] and plan.entries[path].stat
		local stat = entry.stat
		assert(
			old and old.type == stat.type and old.dev == stat.dev and old.ino == stat.ino,
			"source changed after import; original kept: " .. path
		)

		if stat.type == "file" then
			assert(
				old.size == stat.size and old.mtime.sec == stat.mtime.sec and old.mtime.nsec == stat.mtime.nsec,
				"source changed after import; original kept: " .. path
			)
		end
	end
end

function M.transfer(space_id, items, target)
	target = target or {}
	local created = {}
	local plans, err = store.update(function(data)
		local space = store.find(data.spaces, space_id)
		local prepared = preflight(space, items, target)

		for _, plan in ipairs(prepared) do
			if not plan.imported then
				for _, file in ipairs(plan.files) do
					local source = {
						id = store.id(),
						name = vim.fs.basename(file.path),
						original_path = file.path,
						relative_path = file.relative_path,
						folder_id = target.folder_id,
						status = "not_indexed",
						imported_at = os.time(),
						original_stat = {
							size = file.stat.size,
							seconds = file.stat.mtime.sec,
							nanoseconds = file.stat.mtime.nsec,
						},
					}
					source.path = "spaces/" .. space.id .. "/sources/" .. source.id
					local destination = store.directory() .. "/" .. source.path
					assert(uv.fs_copyfile(file.path, destination, { excl = true }))
					table.insert(created, destination)
					table.insert(space.sources, source)
					file.source = source
				end
			end
		end

		return prepared
	end)

	if not plans then
		-- A lock-release failure can follow a committed catalog replacement.
		local persisted = store.catalog()
		local referenced = {}

		for _, space in ipairs(persisted and persisted.spaces or {}) do
			for _, source in ipairs(space.sources) do
				referenced[store.directory() .. "/" .. source.path] = true
			end
		end

		for _, path in ipairs(created) do
			if persisted and not referenced[path] then
				uv.fs_unlink(path)
			end
		end

		return nil, err
	end

	for _, plan in ipairs(plans) do
		if not plan.imported then
			plan.item.knowledge_import = {
				space_id = space_id,
				folder_id = target.folder_id,
				root = plan.root,
				name = plan.name,
				entries = plan.entries,
				files = plan.files,
			}

			for _, file in ipairs(plan.files) do
				local ok, job, failure = pcall(require("aero.knowledge.ingest").start, space_id, file.source.id)

				if not ok or not job then
					vim.notify(
						"Aero knowledge: source imported; indexing could not start: " .. tostring(ok and failure or job),
						vim.log.levels.WARN
					)
				end
			end
		end
	end

	for _, plan in ipairs(plans) do
		if plan.item.action == "cut" then
			local ok, failure = pcall(verify_cut, plan)

			if not ok then
				return nil, tostring(failure)
			end

			if uv.fs_lstat(plan.root) and vim.fn.delete(plan.root, "rf") ~= 0 then
				return nil, "sources imported, but original could not be removed: " .. plan.root
			end
		end

		plan.item.done = true
	end

	return true
end

return M
