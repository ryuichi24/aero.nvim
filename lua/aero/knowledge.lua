-- Local-first knowledge catalog. Source visibility does not imply extraction readiness.
local M = {}
local storage = require("aero.knowledge.store")

function M.directory()
	return storage.directory()
end

local function load()
	return storage.read()
end

local function transaction(callback)
	return storage.update(callback)
end

local function name(value)
	return storage.name(value)
end

local function id()
	return storage.id()
end

local function find(items, key)
	for _, item in ipairs(items) do
		if item.id == key then
			return item
		end
	end

	error("knowledge item no longer exists")
end

function M.catalog()
	local ok, data = pcall(load)

	if not ok then
		return nil, tostring(data)
	end

	return vim.deepcopy(data)
end

function M.create_collection(title)
	return transaction(function(data)
		local item = { id = id(), name = name(title) }
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

function M.add_files(space_id, target)
	target = target or {}
	local data = storage.read()
	local space = find(data.spaces, space_id)
	local collection = find(data.collections, space.collection_id)
	local label = collection.name .. " / " .. space.name

	if target.folder_id then
		label = label .. " / " .. find(space.folders, target.folder_id).name
	end

	if target.directory then
		label = label .. " / " .. target.directory
	end

	return require("aero.file_finder").open({
		home = require("aero.config").options.reference_finder.home,
		target_key = "knowledge:" .. space.id .. ":" .. (target.folder_id or "") .. ":" .. (target.directory or ""),
		title = "Source finder",
		target_kind = "Space",
		target_label = label,
		target_path = label,
		stack_title = "Staged sources",
		transfer = function(items)
			return require("aero.knowledge.import").transfer(space.id, items, target)
		end,
	})
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

		for _, folder in ipairs(space.folders) do
			assert(folder.path ~= path, "folder is already connected")
		end

		local folder = { id = id(), path = path, name = vim.fs.basename(path) }
		table.insert(space.folders, folder)
		return folder
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
	local imported = {}
	local processing = {}

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
						local added = assert(M.add_source(space_id, path, folder.id, relative))
						imported[path] = added
						count = count + 1
					end
				end
			end
		end
	end

	return { changed = count }
end

local function report(value, err)
	if not value then
		vim.notify("Aero knowledge: " .. tostring(err), vim.log.levels.ERROR)
	end

	return value
end

function M.tag_source(space_id, source_id, tags)
	return M.tag_item(space_id, "sources", source_id, tags)
end

function M.tag_note(space_id, note_id, tags)
	return M.tag_item(space_id, "notes", note_id, tags)
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

local function prompt(label, callback)
	vim.ui.input({ prompt = label .. ": " }, function(value)
		if value and vim.trim(value) ~= "" then
			local ok, result, err = pcall(callback, value)
			report(ok and result or nil, ok and err or result)
		end
	end)
end

function M.new_space(collection_id)
	prompt("Space name", function(value)
		return M.create_space(collection_id, value)
	end)
end

local function select(items, label, callback)
	vim.ui.select(items, {
		prompt = label,
		format_item = function(item)
			return item.name
		end,
	}, function(item)
		if item then
			local ok, err = pcall(callback, item)

			if not ok then
				report(nil, err)
			end
		end
	end)
end

local function sessions(scope)
	local agent = require("aero.knowledge.agent")
	local items = agent.sessions(scope)
	table.insert(items, { name = "+ New session" })
	select(items, "Knowledge sessions", function(session)
		if session.key then
			agent.show(session)
		else
			agent.new(scope)
		end
	end)
end

local function search(scope)
	prompt("Search knowledge", function(query)
		require("aero.knowledge.research").search_async(scope, query, 20, function(results, err)
			if not report(results, err) then
				return
			end

			local items = vim.tbl_map(function(result)
				result.name = result.space .. " / " .. result.source .. " · " .. vim.json.encode(result.location)
				return result
			end, results.results)

			if #results.incomplete_sources > 0 then
				vim.notify(
					"Aero knowledge: " .. #results.incomplete_sources .. " sources have incomplete extraction",
					vim.log.levels.WARN
				)
			end

			select(items, "Evidence", require("aero.knowledge.research").open)
		end)
		return true
	end)
end

local function open_document(path)
	require("aero.reader").close_knowledge()
	local win = require("aero.navigation").code_window()

	if win then
		vim.api.nvim_set_current_win(win)
	end

	if path:match("%.pdf$") or path:match("%.pptx$") or path:match("%.xlsx$") or path:match("%.docx$") then
		local _, err = vim.ui.open(path)

		if err then
			report(nil, err)
		end
	else
		vim.cmd("edit " .. vim.fn.fnameescape(path))
		vim.bo.readonly = true
	end
end

function M.browse_space(space, selected_action, source_id, source_action)
	local data = assert(M.catalog())
	space = find(data.spaces, space.id)
	local changes = M.changes(space.id)
	transaction(function(current)
		local item = find(current.spaces, space.id)
		item.last_viewed_at = os.time()
		return item
	end)
	local choices = {
		"Overview",
		"What changed?",
		"Sessions",
		"Search",
		"Browse sources",
		"Tags",
		"Add file",
		"Connect folder",
		"Sync folders",
		"Notes",
		"New note",
		"Save current buffer as note",
		"Jobs",
		"Rename space",
	}
	local function run(action)
		if action == "Add file" then
			M.add_files(space.id)
		elseif action == "Rename space" then
			prompt("Space name", function(value)
				return M.rename("spaces", space.id, value)
			end)
		elseif action == "Browse sources" then
			local sources = vim.deepcopy(space.sources)

			for _, source in ipairs(sources) do
				source.name = (source.relative_path or source.name)
					.. " ["
					.. source.status
					.. "]"
					.. (#(source.tags or {}) > 0 and ("  #" .. table.concat(source.tags, " #")) or "")
			end

			local function browse_source(source)
				local function choose(choice)
					if choice == "Open" then
						local original = find(space.sources, source.id)
						local path = M.directory() .. "/" .. source.path

						if
							original.name:lower():match("%.pdf$")
							or original.name:lower():match("%.pptx$")
							or original.name:lower():match("%.xlsx$")
							or original.name:lower():match("%.docx$")
						then
							local preview = M.directory() .. "/cache/previews/" .. source.id
							vim.fn.mkdir(preview, "p")
							local destination = preview .. "/" .. vim.fs.basename(original.name)
							assert(vim.uv.fs_copyfile(path, destination))
							open_document(destination)
						else
							open_document(path)
							vim.bo.filetype = vim.filetype.match({ filename = original.name, buf = 0 }) or ""
							vim.bo.readonly = true
						end
					elseif choice == "View extracted content" then
						require("aero.knowledge.metadata").extracted_content(space.id, source.id)
					elseif choice == "Refresh from original" then
						report(M.refresh_source(space.id, source.id))
					elseif choice == "Retry extraction" then
						report(require("aero.knowledge.ingest").start(space.id, source.id))
					elseif choice == "Extraction details" then
						require("aero.knowledge.metadata").extraction_details(space.id, source.id)
					elseif choice == "Edit tags" then
						require("aero.knowledge.metadata").edit_tags(space.id, source.id)
					end
				end

				if source_action then
					choose(source_action)
				else
					vim.ui.select({
						"Open",
						"View extracted content",
						"Refresh from original",
						"Retry extraction",
						"Extraction details",
						"Edit tags",
					}, { prompt = source.name }, choose)
				end
			end

			if source_id then
				browse_source(find(sources, source_id))
			else
				select(sources, "Sources", browse_source)
			end
		elseif action == "Tags" then
			local groups = {}

			for _, source in ipairs(space.sources) do
				for _, tag in ipairs(source.tags or {}) do
					groups[tag] = groups[tag] or {}
					table.insert(groups[tag], source)
				end
			end

			for _, note in ipairs(space.notes) do
				for _, tag in ipairs(note.tags or {}) do
					groups[tag] = groups[tag] or {}
					table.insert(groups[tag], { id = note.id, name = note.name .. " [note]", kind = "note" })
				end
			end

			local tags = vim.tbl_keys(groups)
			table.sort(tags)
			local items = {}

			for _, tag in ipairs(tags) do
				local count = #groups[tag]
				table.insert(items, {
					name = "#" .. tag .. " · " .. count .. (count == 1 and " item" or " items"),
					tag = tag,
				})
			end

			if #items == 0 then
				vim.notify("Aero: no source tags in " .. space.name, vim.log.levels.INFO)
				return
			end

			select(items, "Tags · " .. space.name, function(item)
				local sources = vim.deepcopy(groups[item.tag])

				for _, source in ipairs(sources) do
					source.name = source.relative_path or source.name
				end

				select(sources, "Sources and notes tagged #" .. item.tag, function(source)
					if source.kind == "note" then
						require("aero.knowledge.notes").edit(space.id, source.id)
					else
						M.browse_space(space, "Browse sources", source.id)
					end
				end)
			end)
		elseif action == "Sessions" then
			sessions({ space_id = space.id })
		elseif action == "Search" then
			search({ space_id = space.id })
		elseif action == "Connect folder" then
			vim.ui.input({ prompt = "Connect folder: ", completion = "dir" }, function(path)
				if path and path ~= "" then
					report(M.connect_folder(space.id, vim.fn.expand(path)))
				end
			end)
		elseif action == "Sync folders" then
			local ok, result = pcall(M.sync_folders, space.id)
			report(ok and result, result)
		elseif action == "New note" then
			prompt("Note title", function(title)
				return require("aero.knowledge.notes").edit(space.id, nil, title)
			end)
		elseif action == "Save current buffer as note" then
			local win = require("aero.navigation").code_window()
			local buf = win and vim.api.nvim_win_get_buf(win) or vim.api.nvim_get_current_buf()
			local body = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
			prompt("Note title", function(title)
				return require("aero.knowledge.notes").save(space.id, title, body, {})
			end)
		elseif action == "Notes" then
			local items = vim.deepcopy(space.notes)

			for _, item in ipairs(items) do
				if require("aero.knowledge.notes").stale(data, item.citations) then
					item.name = item.name .. " [potentially stale]"
				end
			end

			select(items, action, function(item)
				select(
					{ { name = "Edit" }, { name = "Edit tags" }, { name = item.pinned and "Unpin" or "Pin" } },
					item.name,
					function(choice)
						if choice.name == "Edit" then
							require("aero.knowledge.notes").edit(space.id, item.id)
						elseif choice.name == "Edit tags" then
							require("aero.knowledge.metadata").edit_tags(space.id, item.id, "notes")
						else
							report(require("aero.knowledge.notes").pin(space.id, item.id, not item.pinned))
						end
					end
				)
			end)
		elseif action == "Jobs" then
			local jobs = vim.tbl_filter(function(job)
				return job.space_id == space.id
			end, data.jobs)

			for _, job in ipairs(jobs) do
				job.name = job.kind .. " · " .. job.status .. " · " .. (job.error or job.source_id or job.id)
			end

			select(jobs, "Jobs (processing: cancel · failed/cancelled: retry)", function(job)
				if job.status == "processing" or job.status == "queued" then
					report(require("aero.knowledge.ingest").cancel(job.id))
				elseif job.status == "failed" or job.status == "cancelled" then
					report(require("aero.knowledge.ingest").start(job.space_id, job.source_id))
				end
			end)
		elseif action == "What changed?" then
			local lines = { "Sources added or reprocessed since the previous visit:" }

			for _, source in ipairs(changes.sources) do
				table.insert(lines, "• " .. source.name .. " · " .. source.status)
			end

			table.insert(lines, #changes.stale_notes .. " notes may use older evidence.")
			vim.notify(table.concat(lines, "\n"))
		elseif action == "Overview" then
			vim.notify(
				space.name
					.. "\n"
					.. #space.sources
					.. " sources · "
					.. #space.notes
					.. " notes\nAsk this space via Sessions. Add files or connect a folder to build evidence."
			)
		end
	end

	if selected_action then
		run(selected_action)
	else
		vim.ui.select(choices, { prompt = space.name .. " · Ask this space" }, run)
	end
end

function M.open(collection_id)
	require("aero.knowledge.ingest").recover()
	local data = report(M.catalog())

	if not data then
		return
	end

	local items = vim.deepcopy(data.collections)
	table.insert(items, { name = "+ New collection" })
	table.insert(items, { name = "Cross-collection research", research = true })
	local function open_collection(collection)
		if collection.research then
			local selected = {}
			local function choose()
				local choices = { { name = "Done — browse selected collection sessions", done = true } }

				for _, item in ipairs(data.collections) do
					table.insert(choices, { name = (selected[item.id] and "✓ " or "  ") .. item.name, id = item.id })
				end

				select(choices, "Explicitly select collections", function(item)
					if item.done then
						local ids = vim.tbl_keys(selected)

						if #ids == 0 then
							report(nil, "select at least one collection")
						else
							sessions({ collection_ids = ids })
						end
					else
						selected[item.id] = not selected[item.id] and true or nil
						choose()
					end
				end)
			end

			choose()
			return
		end

		if not collection.id then
			prompt("Collection name", M.create_collection)
			return
		end

		local spaces = vim.tbl_filter(function(space)
			return space.collection_id == collection.id
		end, data.spaces)
		table.insert(spaces, { name = "+ New space" })
		table.insert(spaces, { name = "Rename collection", rename = true })
		table.insert(spaces, { name = "Collection sessions", sessions = true })
		table.insert(spaces, { name = "Search collection", search = true })
		select(spaces, collection.name, function(space)
			if space.sessions then
				sessions({ collection_id = collection.id })
			elseif space.search then
				search({ collection_id = collection.id })
			elseif space.rename then
				prompt("Collection name", function(value)
					return M.rename("collections", collection.id, value)
				end)
			elseif not space.id then
				M.new_space(collection.id)
			else
				M.browse_space(space)
			end
		end)
	end

	if collection_id then
		for _, collection in ipairs(data.collections) do
			if collection.id == collection_id then
				open_collection(collection)
				return
			end
		end
	else
		select(items, "Knowledge base", open_collection)
	end
end

-- Composer shortcuts use the owning chat, rather than the dashboard selection.
function M.pick_sources(session, kind)
	local agent = require("aero.knowledge.agent")
	local scope = agent.scope(session)

	if not scope then
		return
	end

	if session.chat and session.chat.busy then
		return report(nil, "finish the current agent turn before changing sources")
	end

	local items, tags = {}, {}

	for _, space in ipairs(storage.scope(storage.read(), scope)) do
		for _, source in ipairs(space.sources) do
			table.insert(items, {
				name = space.name
					.. " / "
					.. (source.relative_path or source.name)
					.. (#(source.tags or {}) > 0 and ("  #" .. table.concat(source.tags, " #")) or ""),
				source_ids = { source.id },
			})

			for _, tag in ipairs(source.tags or {}) do
				tags[tag] = tags[tag] or {}
				table.insert(tags[tag], source.id)
			end
		end
	end

	if kind == "tag" then
		items = {}

		for _, tag in ipairs(vim.fn.sort(vim.tbl_keys(tags))) do
			table.insert(items, { name = "#" .. tag .. " (" .. #tags[tag] .. " sources)", source_ids = tags[tag] })
		end
	end

	if #items == 0 then
		return report(nil, kind == "tag" and "no source tags in this scope" or "no sources in this scope")
	end

	table.insert(items, 1, { name = "All sources" })
	return select(items, kind == "tag" and "Choose source tag" or "Choose session source", function(item)
		report(agent.filter(session, item.source_ids))
	end)
end

function M.command(args, opts)
	if #args == 0 then
		return M.open()
	end

	local session = require("aero.session_target").resolve("viewed")
	local agent = require("aero.knowledge.agent")
	local scope = session and agent.scope(session)

	if not scope then
		return report(nil, "select a knowledge session first")
	end

	if args[1] == "status" and #args == 1 then
		return agent.status(session)
	elseif args[1] == "note" and #args == 1 then
		if not scope.space_id then
			return report(nil, "save notes from a space session")
		end

		local first, last =
			opts.range > 0 and opts.line1 or 1, opts.range > 0 and opts.line2 or vim.api.nvim_buf_line_count(0)
		local body = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n")
		return prompt("Save finding as note", function(title)
			return require("aero.knowledge.notes").save(scope.space_id, title, body, {}, nil, session.key)
		end)
	elseif args[1] == "selection" and #args == 1 then
		local first, last =
			opts.range > 0 and opts.line1 or 1, opts.range > 0 and opts.line2 or vim.api.nvim_buf_line_count(0)
		local path = vim.api.nvim_buf_get_name(0)
		local text = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), "\n")
		return require("aero.compose").append(
			session,
			"Selected evidence: " .. path .. ":" .. first .. "–" .. last .. "\n\n" .. text .. "\n\nQuestion: "
		)
	elseif args[1] == "scope" and #args == 1 then
		local items = { { name = "All sources" }, { name = "Choose multiple files…", choose = true } }
		local files, groups = {}, {}

		for _, space in ipairs(storage.scope(storage.read(), scope)) do
			for _, source in ipairs(space.sources) do
				local item =
					{ name = space.name .. " / " .. (source.relative_path or source.name), source_ids = { source.id } }
				table.insert(items, item)
				table.insert(files, item)
				local labels = vim.tbl_map(function(tag)
					return "Tag: " .. tag
				end, source.tags or {})

				if source.folder_id then
					table.insert(
						labels,
						"Folder: " .. space.name .. " / " .. find(space.folders, source.folder_id).name
					)
				end

				for _, label in ipairs(labels) do
					groups[label] = groups[label] or {}
					table.insert(groups[label], source.id)
				end
			end

			for _, source_set in ipairs(space.source_sets) do
				table.insert(items, {
					name = "Saved set: " .. space.name .. " / " .. source_set.name,
					source_ids = source_set.source_ids,
				})
			end
		end

		for label, source_ids in pairs(groups) do
			table.insert(items, { name = label, source_ids = source_ids })
		end

		return select(items, "Session scope", function(item)
			if not item.choose then
				report(agent.filter(session, item.source_ids))
				return
			end

			local selected = {}

			for _, source_id in ipairs(scope.source_ids or {}) do
				selected[source_id] = true
			end

			local function choose()
				local choices = { { name = "Done — apply selected files", done = true } }

				for _, file in ipairs(files) do
					local key = file.source_ids[1]
					table.insert(choices, { name = (selected[key] and "✓ " or "  ") .. file.name, key = key })
				end

				select(choices, "Choose source files", function(choice)
					if choice.done then
						report(agent.filter(session, vim.tbl_keys(selected)))
					else
						selected[choice.key] = not selected[choice.key] and true or nil
						choose()
					end
				end)
			end

			choose()
		end)
	elseif args[1] == "set" and #args == 1 then
		if not scope.space_id or not scope.source_ids then
			return report(nil, "choose source files in a space session before saving a set")
		end

		return prompt("Source set name", function(title)
			return M.save_source_set(scope.space_id, title, scope.source_ids)
		end)
	end

	return report(nil, "use :Aero knowledge [scope|set|selection|note]")
end

return M
