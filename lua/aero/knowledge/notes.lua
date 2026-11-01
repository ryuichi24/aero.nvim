local store = require("aero.knowledge.store")
local M = {}

function M.pin(space_id, note_id, pinned)
	return store.update(function(data)
		local note = store.find(store.find(data.spaces, space_id).notes, note_id)
		note.pinned = pinned == true
		return note
	end)
end

function M.save(space_id, title, body, citations, note_id, session_key, expected_revision)
	return store.update(function(data)
		local space = store.find(data.spaces, space_id)
		local previous = note_id and store.find(space.notes, note_id)
		assert(
			not expected_revision or previous and previous.revision == expected_revision,
			"note changed elsewhere; reopen it before saving"
		)
		citations = citations or previous and previous.citations or {}
		local references = {}

		for _, citation in ipairs(citations or {}) do
			local source_space = store.find(data.spaces, citation.space_id)
			assert(source_space.collection_id == space.collection_id, "citation is outside this collection")
			local source = store.find(source_space.sources, citation.source_id)
			assert(
				source.version == citation.version or previous and vim.deep_equal(citations, previous.citations),
				"citation uses an outdated source version"
			)
			assert(
				type(citation.chunk) == "number"
					and citation.chunk >= 1
					and citation.chunk == math.floor(citation.chunk),
				"citation requires a one-based chunk"
			)
			require("aero.knowledge.research").read(
				{ space_id = source_space.id },
				source.id,
				citation.chunk,
				citation.chunk,
				citation.version
			)
			table.insert(references, vim.deepcopy(citation))
		end

		assert(type(body) == "string" and vim.trim(body) ~= "", "note body must not be empty")
		local note = previous or { id = store.id(), versions = {} }
		note.name, note.citations, note.session_key = store.name(title), references, session_key
		note.revision = (note.revision or 0) + 1
		note.updated_at = os.time()
		note.path = "spaces/" .. space.id .. "/notes/" .. note.id .. "-" .. note.revision .. ".md"
		assert(
			vim.fn.writefile(vim.split(body, "\n", { plain = true }), store.directory() .. "/" .. note.path) == 0,
			"cannot write note"
		)
		table.insert(note.versions, { path = note.path, citations = references, revision = note.revision })

		if not note_id then
			table.insert(space.notes, note)
		end

		return note
	end)
end

function M.edit(space_id, note_id, title)
	local space = store.find(store.read().spaces, space_id)
	local note = note_id and store.find(space.notes, note_id) or { name = store.name(title) }
	local revision = note.revision
	local buf = vim.api.nvim_create_buf(true, true)

	if note.path then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.fn.readfile(store.directory() .. "/" .. note.path))
	end

	vim.bo[buf].buftype, vim.bo[buf].filetype = "acwrite", "markdown"
	vim.api.nvim_buf_set_name(buf, "aero-note://" .. (note_id or "new") .. "/" .. buf)
	vim.keymap.set("n", "gt", function()
		if not note_id then
			vim.notify("Aero knowledge: save the note before editing tags", vim.log.levels.INFO)
			return
		end

		require("aero.knowledge.metadata").edit_tags(space_id, note_id, "notes")
	end, { buffer = buf, desc = "Edit note tags" })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			local current = note_id and store.find(store.find(store.read().spaces, space_id).notes, note_id) or note

			if current.revision ~= revision then
				vim.notify("Aero knowledge: note changed elsewhere; reopen it before editing", vim.log.levels.ERROR)
				return
			end

			local saved, err = M.save(
				space_id,
				current.name,
				table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"),
				nil,
				note_id,
				current.session_key,
				revision
			)

			if saved then
				note_id = saved.id
				revision = saved.revision
				vim.bo[buf].modified = false
			else
				vim.notify(tostring(err), vim.log.levels.ERROR)
			end
		end,
	})
	local win = require("aero.navigation").code_window()

	if win then
		vim.api.nvim_set_current_win(win)
	end

	vim.api.nvim_set_current_buf(buf)
	vim.bo[buf].modified = false
	return buf
end

function M.stale(data, citations)
	for _, citation in ipairs(citations or {}) do
		local found = false

		for _, space in ipairs(data.spaces) do
			for _, source in ipairs(space.sources) do
				if source.id == citation.source_id and space.id == citation.space_id then
					found = source.version == citation.version
				end
			end
		end

		if not found then
			return true
		end
	end

	return false
end

return M
