-- Catalog/source operations. Interactive browsing is owned by knowledge.ui.
local storage = require("aero.knowledge.store")
local M = {}
local transaction = storage.update
local name, id = storage.name, storage.id

local function find(items, key)
	for _, item in ipairs(items) do
		if item.id == key then
			return item
		end
	end

	error("knowledge item no longer exists")
end

function M.directory()
	return storage.directory()
end

function M.catalog()
	local ok, data = pcall(storage.read)

	if not ok then
		return nil, tostring(data)
	end

	data.collections = vim.tbl_filter(require("aero.scenes").owns, data.collections)
	local visible = {}

	for _, collection in ipairs(data.collections) do
		visible[collection.id] = true
	end

	data.spaces = vim.tbl_filter(function(space)
		return visible[space.collection_id] == true
	end, data.spaces)
	return vim.deepcopy(data)
end

function M.create_collection(title)
	return transaction(function(data)
		local item = { id = id(), name = name(title), scene_id = require("aero.scenes").current() }
		table.insert(data.collections, item)
		return item
	end)
end

function M.create_space(collection_id, title)
	return transaction(function(data)
		find(data.collections, collection_id)
		local item = { id = id(), name = name(title), collection_id = collection_id, sources = {} }
		local directory = M.directory() .. "/spaces/" .. item.id

		for _, folder in ipairs({ "sources", "notes" }) do
			vim.fn.mkdir(directory .. "/" .. folder, "p")
		end

		table.insert(data.spaces, item)
		return item
	end)
end

function M.rename(kind, key, title)
	return transaction(function(data)
		assert(kind == "collections" or kind == "spaces", "invalid knowledge kind")
		local item = find(data[kind], key)
		item.name = name(title)
		return item
	end)
end

function M.rename_source(space_id, source_id, title)
	return transaction(function(data)
		local source = find(find(data.spaces, space_id).sources, source_id)
		source.relative_path = source.relative_path or source.name
		source.name = name(title)
		return source
	end)
end

function M.delete_item(space_id, kind, key)
	return transaction(function(data)
		local space = find(data.spaces, space_id)
		assert(
			kind == "notes" or kind == "sources" or kind == "folders" or kind == "directory",
			"invalid knowledge item"
		)
		local source_ids = {}

		if kind == "notes" then
			find(space.notes, key)
			space.notes = vim.tbl_filter(function(note)
				return note.id ~= key
			end, space.notes)
			return true
		end

		if kind == "sources" or kind == "folders" then
			find(space[kind], key)
		end

		for _, source in ipairs(space.sources) do
			if
				kind == "sources" and source.id == key
				or kind == "folders" and source.folder_id == key
				or kind == "directory"
					and not source.folder_id
					and vim.startswith(source.relative_path or source.name, key .. "/")
			then
				source_ids[source.id] = true
			end
		end

		for _, job in ipairs(data.jobs) do
			assert(
				not (source_ids[job.source_id] and (job.status == "processing" or job.status == "queued")),
				"cancel extraction before deleting this source"
			)
		end

		space.sources = vim.tbl_filter(function(source)
			return not source_ids[source.id]
		end, space.sources)

		if kind == "folders" then
			space.folders = vim.tbl_filter(function(folder)
				return folder.id ~= key
			end, space.folders)
		end

		return true
	end)
end

function M.add_source(space_id, path, folder_id, relative_path)
	local source, err = transaction(function(data)
		local space = find(data.spaces, space_id)
		path = require("aero.storage").canonical(path)
		local stat = vim.uv.fs_stat(path)
		assert(stat and stat.type == "file", "source must be a readable regular file")
		local source = {
			id = id(),
			name = vim.fs.basename(path),
			original_path = path,
			status = "not_indexed",
			imported_at = os.time(),
			original_stat = { size = stat.size, seconds = stat.mtime.sec, nanoseconds = stat.mtime.nsec },
			folder_id = folder_id,
			relative_path = relative_path,
		}
		local destination = M.directory() .. "/spaces/" .. space.id .. "/sources/" .. source.id
		assert(vim.uv.fs_copyfile(path, destination))
		source.path = "spaces/" .. space.id .. "/sources/" .. source.id
		table.insert(space.sources, source)
		return source
	end)

	if source then
		require("aero.knowledge.ingest").start(space_id, source.id)
	end

	return source, err
end

function M.refresh_source(space_id, source_id)
	local source, err = transaction(function(data)
		local item = find(find(data.spaces, space_id).sources, source_id)

		for _, job in ipairs(data.jobs) do
			assert(
				not (job.source_id == source_id and (job.status == "processing" or job.status == "queued")),
				"cancel extraction before refreshing this source"
			)
		end

		local destination = M.directory() .. "/" .. item.path

		if item.version then
			local history = M.directory() .. "/history/" .. item.id
			vim.fn.mkdir(history, "p")
			assert(vim.uv.fs_copyfile(destination, history .. "/" .. item.version))
		end

		assert(vim.uv.fs_copyfile(item.original_path, destination))
		local stat = assert(vim.uv.fs_stat(item.original_path))
		item.original_stat = { size = stat.size, seconds = stat.mtime.sec, nanoseconds = stat.mtime.nsec }
		item.status, item.extraction, item.version = "not_indexed", nil, nil
		return item
	end)

	if source then
		return require("aero.knowledge.ingest").start(space_id, source_id)
	end

	return nil, err
end

function M.connect_folder(space_id, path)
	path = require("aero.storage").canonical(path)
	local folder, err = transaction(function(data)
		assert(vim.fn.isdirectory(path) == 1, "select a folder")
		local paths = require("aero.storage")
		assert(
			path ~= M.directory() and not paths.inside(path, M.directory()) and not paths.inside(M.directory(), path),
			"connected folder must not contain or be inside managed knowledge storage"
		)
		local space = find(data.spaces, space_id)

		for _, existing in ipairs(space.folders) do
			assert(existing.path ~= path, "folder is already connected")
		end

		local item = { id = id(), path = path, name = vim.fs.basename(path) }
		table.insert(space.folders, item)
		return item
	end)

	if folder then
		local ok, failure = pcall(M.sync_folders, space_id)

		if not ok then
			vim.notify(
				"Aero knowledge: folder connected; initial sync failed: " .. tostring(failure),
				vim.log.levels.WARN
			)
		end
	end

	return folder, err
end

function M.sync_folders(space_id)
	local data = assert(M.catalog())
	local space = find(data.spaces, space_id)
	local imported, processing = {}, {}

	for _, job in ipairs(data.jobs) do
		if (job.status == "processing" or job.status == "queued") and job.source_id then
			processing[job.source_id] = true
		end
	end

	for _, source in ipairs(space.sources) do
		imported[source.original_path] = source
	end

	local count = 0
	local extensions = {
		"md",
		"markdown",
		"txt",
		"csv",
		"pdf",
		"xlsx",
		"pptx",
		"docx",
		"png",
		"jpg",
		"jpeg",
		"tif",
		"tiff",
		"bmp",
		"webp",
	}

	for _, adapter in ipairs(require("aero.config").options.knowledge.extractors) do
		for _, extension in ipairs(adapter.extensions) do
			table.insert(extensions, extension:sub(2))
		end
	end

	for _, folder in ipairs(space.folders) do
		for relative, kind in vim.fs.dir(folder.path, { depth = 20 }) do
			if kind == "file" and relative:lower():match("%.(.*)$") then
				local extension = relative:lower():match("%.([^.]*)$")

				if vim.tbl_contains(extensions, extension) then
					local path = folder.path .. "/" .. relative
					local existing = imported[path]

					if existing and not processing[existing.id] then
						local stat = assert(vim.uv.fs_stat(path))
						local previous = existing.original_stat or {}

						if
							previous.size ~= stat.size
							or previous.seconds ~= stat.mtime.sec
							or previous.nanoseconds ~= stat.mtime.nsec
						then
							assert(M.refresh_source(space_id, existing.id))
							count = count + 1
						end
					elseif not existing then
						imported[path] = assert(M.add_source(space_id, path, folder.id, relative))
						count = count + 1
					end
				end
			end
		end
	end

	return { changed = count }
end

function M.tag_item(space_id, kind, item_id, tags)
	return transaction(function(data)
		assert(kind == "sources" or kind == "notes", "invalid tagged item kind")
		local source = find(find(data.spaces, space_id)[kind], item_id)
		assert(vim.islist(tags), "tags must be a list")
		local selected = {}

		for _, tag in ipairs(tags) do
			selected[name(tag)] = true
		end

		source.tags = vim.tbl_keys(selected)
		table.sort(source.tags)
		return source
	end)
end

function M.tag_source(space_id, source_id, tags)
	return M.tag_item(space_id, "sources", source_id, tags)
end

function M.tag_note(space_id, note_id, tags)
	return M.tag_item(space_id, "notes", note_id, tags)
end

function M.save_source_set(space_id, title, source_ids)
	return transaction(function(data)
		local space = find(data.spaces, space_id)
		assert(vim.islist(source_ids) and #source_ids > 0, "select source files before saving a source set")

		for _, key in ipairs(source_ids) do
			find(space.sources, key)
		end

		local item = { id = id(), name = name(title), source_ids = vim.deepcopy(source_ids) }
		table.insert(space.source_sets, item)
		return item
	end)
end

function M.changes(space_id, since)
	local data = storage.read()
	local space = find(data.spaces, space_id)
	local result = { sources = {}, stale_notes = {}, since = since or space.last_viewed_at or 0 }

	for _, source in ipairs(space.sources) do
		if math.max(source.imported_at or 0, source.indexed_at or 0) >= result.since then
			table.insert(
				result.sources,
				{ id = source.id, name = source.name, version = source.version, status = source.status }
			)
		end
	end

	for _, item in ipairs(space.notes) do
		if require("aero.knowledge.notes").stale(data, item.citations) then
			table.insert(result.stale_notes, { id = item.id, name = item.name })
		end
	end

	return result
end

return M
