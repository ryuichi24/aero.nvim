-- Scope is applied before reading evidence; locations always retain their space and version.
local store = require("aero.knowledge.store")
local M = {}

function M.uri(citation)
	return "aero-knowledge://"
		.. citation.space_id
		.. "/"
		.. citation.source_id
		.. "/"
		.. citation.version
		.. "/"
		.. citation.chunk
end

function M.parse_uri(uri)
	if type(uri) ~= "string" then
		return
	end

	local space, source, version, chunk = uri:match("^aero%-knowledge://(%x+)/(%x+)/(%x+)/(%d+)$")

	if space and #version == 64 and tonumber(chunk) >= 1 then
		return { space_id = space, source_id = source, version = version, chunk = tonumber(chunk) }
	end
end

function M.follow_cursor()
	local line = vim.api.nvim_get_current_line()
	local column = vim.api.nvim_win_get_cursor(0)[2] + 1

	for first, uri, last in line:gmatch("()%[[^%]]+%]%((aero%-knowledge://[%w/._-]+)%)()") do
		if column >= first and column < last then
			local citation = M.parse_uri(uri)

			if citation then
				local ok, err = pcall(M.open, citation)

				if not ok then
					vim.notify("Aero knowledge: " .. tostring(err), vim.log.levels.ERROR)
				end

				return true
			end
		end
	end

	return false
end

local function extracted(source, version)
	version = version or source.version
	assert(
		type(version) == "string" and #version == 64 and version:match("^%x+$"),
		"source has not been extracted or has an invalid version"
	)
	local path = store.directory() .. "/cache/" .. source.id .. "/" .. version .. ".json"
	local document = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	assert(document.version == version, "extraction version mismatch")
	return document
end

function M.search(scope, query, limit, embedding)
	assert(type(query) == "string" and vim.trim(query) ~= "", "enter a search query")
	local terms, results, pending, warnings = {}, {}, {}, {}

	for term in query:lower():gmatch("%S+") do
		table.insert(terms, term)
	end

	local data = store.read()

	for _, space in ipairs(store.scope(data, scope)) do
		for _, source in ipairs(space.sources) do
			if not scope.source_ids or vim.tbl_contains(scope.source_ids, source.id) then
				if source.extraction then
					local document = extracted(source)

					for index, chunk in ipairs(document.chunks) do
						local score = 0

						for _, term in ipairs(terms) do
							if chunk.text:lower():find(term, 1, true) then
								score = score + 1
							end
						end

						if embedding and embedding.model == document.embedding_model then
							score = score / #terms
								+ math.max(
									0,
									require("aero.knowledge.semantic").similarity(embedding.vector, chunk.vector)
								)
						end

						if score > 0 then
							table.insert(results, {
								space_id = space.id,
								space = space.name,
								source_id = source.id,
								source = source.name,
								version = source.version,
								chunk = index,
								location = chunk.location,
								text = chunk.text,
								score = score,
							})
						end
					end
				end

				if source.status ~= "ready" then
					table.insert(source.status == "ready_with_warnings" and warnings or pending, {
						space = space.name,
						source = source.name,
						status = source.status,
						issues = source.issues,
						error = source.error,
					})
				end
			end
		end

		if not scope.source_ids then
			for _, note in ipairs(space.notes) do
				local text = table.concat(vim.fn.readfile(store.directory() .. "/" .. note.path), "\n")
				local score = 0

				for _, term in ipairs(terms) do
					if text:lower():find(term, 1, true) then
						score = score + 1
					end
				end

				if score > 0 then
					table.insert(results, {
						space_id = space.id,
						space = space.name,
						source_id = note.id,
						source = note.name,
						version = tostring(note.revision),
						chunk = 1,
						location = { note = note.id },
						text = text,
						score = score,
						kind = "note",
						citations = note.citations,
						stale = require("aero.knowledge.notes").stale(data, note.citations),
					})
				end
			end
		end
	end

	table.sort(results, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end

		return a.source_id .. ":" .. a.chunk < b.source_id .. ":" .. b.chunk
	end)
	local total_results = #results
	limit = math.min(math.max(tonumber(limit) or 20, 1), 100)
	while #results > limit do
		table.remove(results)
	end

	for _, result in ipairs(results) do
		if result.kind ~= "note" then
			result.uri = M.uri(result)
		end
	end

	return { results = results, total_results = total_results, incomplete_sources = pending, warning_sources = warnings }
end

function M.search_async(scope, query, limit, callback)
	require("aero.knowledge.semantic").query(query, function(embedding, warning)
		local ok, result = pcall(M.search, scope, query, limit, embedding)

		if ok then
			result.semantic_warning = warning
			callback(result)
		else
			callback(nil, tostring(result))
		end
	end)
end

function M.read(scope, source_id, first, last, version)
	for _, space in ipairs(store.scope(store.read(), scope)) do
		for _, source in ipairs(space.sources) do
			if source.id == source_id and (not scope.source_ids or vim.tbl_contains(scope.source_ids, source_id)) then
				local document = extracted(source, version)
				local chunks = {}
				first = math.max(tonumber(first) or 1, 1)
				last = math.min(tonumber(last) or first + 9, first + 99, #document.chunks)
				assert(
					first == math.floor(first) and last == math.floor(last) and first <= last,
					"requested chunk range is unavailable"
				)

				for index = first, last do
					chunks[#chunks + 1] = {
						chunk = index,
						text = document.chunks[index].text,
						location = document.chunks[index].location,
						uri = M.uri({
							space_id = space.id,
							source_id = source.id,
							version = document.version,
							chunk = index,
						}),
					}
				end

				return {
					space_id = space.id,
					space = space.name,
					source_id = source.id,
					source = source.name,
					version = document.version,
					chunks = chunks,
					total_chunks = #document.chunks,
					issues = document.issues,
				}
			end
		end
	end

	error("source is outside the selected scope")
end

function M.table(scope, source_id, table_name)
	local data = store.read()

	for _, space in ipairs(store.scope(data, scope)) do
		for _, source in ipairs(space.sources) do
			if source.id == source_id and (not scope.source_ids or vim.tbl_contains(scope.source_ids, source_id)) then
				for _, dataset in ipairs(extracted(source).tables) do
					if dataset.name == table_name then
						return dataset
					end
				end
			end
		end
	end

	error("table not found")
end

function M.open(citation)
	if citation.kind == "note" then
		local note = store.find(store.find(store.read().spaces, citation.space_id).notes, citation.source_id)
		return require("aero.knowledge.notes").edit(citation.space_id, note.id)
	end

	local result =
		M.read({ space_id = citation.space_id }, citation.source_id, citation.chunk, citation.chunk, citation.version)
	local source = store.find(store.find(store.read().spaces, citation.space_id).sources, citation.source_id)
	local location = result.chunks[1].location

	if location.line then
		local path = source.version == citation.version and store.directory() .. "/" .. source.path
			or store.directory() .. "/history/" .. source.id .. "/" .. citation.version
		local win = require("aero.navigation").code_window()

		if win then
			vim.api.nvim_set_current_win(win)
		end

		vim.cmd("edit " .. vim.fn.fnameescape(path))
		vim.bo.filetype = vim.filetype.match({ filename = source.name, buf = 0 }) or ""
		vim.bo.readonly = true
		vim.api.nvim_win_set_cursor(0, { location.line, 0 })
	else
		local buf = vim.api.nvim_create_buf(false, true)
		local lines = {
			"# " .. result.space .. " / " .. result.source,
			"Version: " .. result.version,
			"Location: " .. vim.json.encode(location),
			"",
		}
		vim.list_extend(lines, vim.split(result.chunks[1].text, "\n", { plain = true }))
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.api.nvim_set_current_buf(buf)
		vim.bo[buf].filetype = "markdown"
		vim.bo[buf].modifiable = false
	end
end

return M
