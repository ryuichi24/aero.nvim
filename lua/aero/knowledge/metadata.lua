-- Source inspection buffers and tags persisted on :write.
local M = {}
local previews = {}

local function inspect_buffer(space_id, source_id, kind, name, lines, filetype)
	local buf = vim.fn.bufnr(name)

	if buf == -1 then
		buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(buf, name)
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].filetype = filetype
		vim.keymap.set("n", "q", function()
			require("aero.reader").close_knowledge()
		end, { buffer = buf, desc = "Return to previous reader view" })
	end

	local win = vim.fn.bufwinid(buf)
	local view = win ~= -1 and vim.api.nvim_win_call(win, vim.fn.winsaveview)
	vim.bo[buf].readonly = false
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true

	if view then
		vim.api.nvim_win_call(win, function()
			vim.fn.winrestview(view)
		end)
	end

	require("aero.reader").open_knowledge(space_id, source_id, kind, buf)
	return buf
end

function M.extraction_details(space_id, source_id)
	local store = require("aero.knowledge.store")
	local source = store.find(store.find(store.read().spaces, space_id).sources, source_id)
	return inspect_buffer(
		space_id,
		source_id,
		"metadata",
		"aero://knowledge/extraction/" .. source.id,
		vim.split(vim.inspect(source), "\n", { plain = true }),
		"lua"
	)
end

function M.extracted_content(space_id, source_id)
	local store = require("aero.knowledge.store")
	local source = store.find(store.find(store.read().spaces, space_id).sources, source_id)

	if not source.extraction then
		return vim.notify(
			"Aero knowledge: no extracted content yet; check Extraction details or retry extraction",
			vim.log.levels.WARN
		)
	end

	local ok, document = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(store.directory() .. "/" .. source.extraction), "\n"))
	end)

	if not ok or type(document) ~= "table" or type(document.chunks) ~= "table" or type(document.tables) ~= "table" then
		return vim.notify("Aero knowledge: extraction cache is unavailable; retry extraction", vim.log.levels.ERROR)
	end

	local lines = {
		"# Extracted content: " .. source.name,
		"",
		"Status: " .. source.status,
		"Version: " .. tostring(document.version),
		"",
		"## Warnings",
		"",
	}

	if source.error then
		vim.list_extend(lines, vim.split(source.error, "\n", { plain = true }))
	end

	for _, issue in ipairs(document.issues or {}) do
		vim.list_extend(lines, vim.split("- " .. issue, "\n", { plain = true }))
	end

	if not source.error and #(document.issues or {}) == 0 then
		table.insert(lines, "None.")
	end

	vim.list_extend(lines, { "", "## Text chunks (" .. #document.chunks .. ")", "" })

	for index, chunk in ipairs(document.chunks) do
		vim.list_extend(lines, { "### Chunk " .. index, "", "Location: " .. vim.json.encode(chunk.location), "" })
		vim.list_extend(lines, vim.split(chunk.text, "\n", { plain = true }))
		table.insert(lines, "")
	end

	vim.list_extend(lines, { "## Tables (" .. #document.tables .. ")", "" })

	for _, dataset in ipairs(document.tables) do
		vim.list_extend(lines, {
			"### " .. dataset.name,
			"",
			"Rows are JSON arrays of string cells; empty rows and cells preserve positions.",
			"",
			"```json",
			"[",
		})

		for index, row in ipairs(dataset.rows) do
			table.insert(lines, "  " .. vim.json.encode(row) .. (index < #dataset.rows and "," or ""))
		end

		vim.list_extend(lines, { "]", "```", "" })
	end

	return inspect_buffer(space_id, source_id, "content", "aero://knowledge/content/" .. source.id, lines, "markdown")
end

local function preview(buf, space_id)
	local state = previews[buf]

	if not state then
		state = {}
		previews[buf] = state
		local function close()
			local win = state.win
			state.win = nil
			vim.schedule(function()
				if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == state.buf then
					vim.api.nvim_win_close(win, true)
				end
			end)
		end

		vim.api.nvim_create_autocmd({ "BufHidden", "BufWipeout" }, { buffer = buf, callback = close })
		vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI", "TextChanged", "TextChangedI", "BufEnter" }, {
			buffer = buf,
			callback = function()
				preview(buf, space_id)
			end,
		})
	end

	if vim.api.nvim_get_current_buf() ~= buf then
		return
	end

	local tag = vim.trim(vim.api.nvim_get_current_line())
	local data = require("aero.knowledge").catalog()
	local space = data and require("aero.knowledge.store").find(data.spaces, space_id)
	local lines = {}
	state.sources = {}
	state.space = space

	for _, source in ipairs(space and space.sources or {}) do
		if tag ~= "" and vim.tbl_contains(source.tags or {}, tag) then
			table.insert(lines, (source.relative_path or source.name) .. " [" .. source.status .. "]")
			table.insert(state.sources, source)
		end
	end

	for _, note in ipairs(space and space.notes or {}) do
		if tag ~= "" and vim.tbl_contains(note.tags or {}, tag) then
			table.insert(lines, note.name .. " [note]")
			table.insert(state.sources, { id = note.id, kind = "note" })
		end
	end

	local count = #lines

	if count == 0 then
		lines = { tag == "" and "Move to a tag to see matching items." or "No saved items with this tag." }
	end

	if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
		state.buf = vim.api.nvim_create_buf(false, true)
		vim.bo[state.buf].bufhidden = "wipe"
		vim.bo[state.buf].filetype = "text"
		vim.keymap.set("n", "<CR>", function()
			local source = state.sources[vim.api.nvim_win_get_cursor(0)[1]]

			if source then
				if source.kind == "note" then
					require("aero.knowledge.notes").edit(space_id, source.id)
				else
					require("aero.knowledge").browse_space(state.space, "Browse sources", source.id, "Open")
				end
			end
		end, { buffer = state.buf, desc = "Open source" })
	end

	vim.bo[state.buf].modifiable = true
	vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
	vim.bo[state.buf].modifiable = false
	local win = vim.api.nvim_get_current_win()

	if not state.win or not vim.api.nvim_win_is_valid(state.win) then
		state.win = vim.api.nvim_open_win(state.buf, false, { split = "right", win = win })
	end

	vim.wo[state.win].statusline = " Sources and notes · #" .. tag:gsub("%%", "%%%%") .. " · " .. count .. " items"
end

function M.tag_candidates(space_id, buf)
	local store = require("aero.knowledge.store")
	local space = store.find(store.read().spaces, space_id)
	local registered, used = {}, {}
	local row, column = unpack(vim.api.nvim_win_get_cursor(0))
	local query = vim.trim(vim.api.nvim_get_current_line():sub(1, column)):lower()

	for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if index ~= row then
			used[vim.trim(line)] = true
		end
	end

	for _, kind in ipairs({ "sources", "notes" }) do
		for _, item in ipairs(space[kind]) do
			for _, tag in ipairs(item.tags or {}) do
				registered[tag] = true
			end
		end
	end

	local tags = vim.tbl_keys(registered)
	table.sort(tags)
	local items = {}

	for _, tag in ipairs(tags) do
		if not used[tag] and tag:lower():find(query, 1, true) then
			table.insert(items, { word = tag, abbr = tag, menu = "Existing tag" })
		end
	end

	return 1, items
end

function M.edit_tags(space_id, source_id, kind)
	kind = kind or "sources"
	assert(kind == "sources" or kind == "notes", "invalid tagged item kind")
	local knowledge = require("aero.knowledge")
	local store = require("aero.knowledge.store")
	local function source()
		return store.find(store.find(assert(knowledge.catalog()).spaces, space_id)[kind], source_id)
	end

	local initial = source()
	local name = (kind == "notes" and "aero-note-tags://" or "aero-source-tags://") .. space_id .. "/" .. source_id
	local buf = vim.fn.bufnr(name)

	if buf == -1 then
		buf = vim.api.nvim_create_buf(true, true)
		vim.api.nvim_buf_set_name(buf, name)
		vim.bo[buf].buftype, vim.bo[buf].filetype = "acwrite", "text"
		vim.bo[buf].bufhidden = "hide"
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial.tags or {})
		vim.bo[buf].modified = false
		local previous = vim.deepcopy(initial.tags or {})
		require("aero.acp.completion").setup(buf, nil, function()
			return M.tag_candidates(space_id, buf)
		end)
		vim.keymap.set("i", "<CR>", function()
			if not require("aero.acp.path_menu").accept(buf) then
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "in", false)
			end
		end, { buffer = buf, desc = "Accept tag suggestion or insert newline" })
		vim.keymap.set("n", "<CR>", function()
			preview(buf, space_id)
			vim.api.nvim_set_current_win(previews[buf].win)
		end, { buffer = buf, desc = "Focus sources and notes with tag under cursor" })
		vim.api.nvim_create_autocmd("BufWriteCmd", {
			buffer = buf,
			callback = function()
				local ok, saved, err = pcall(function()
					assert(
						vim.deep_equal(source().tags or {}, previous),
						"tags changed elsewhere; :bwipeout! and reopen the editor"
					)
					local tags = {}

					for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
						local tag = vim.trim(line)

						if tag ~= "" then
							table.insert(tags, tag)
						end
					end

					return knowledge.tag_item(space_id, kind, source_id, tags)
				end)

				if ok and saved then
					previous = vim.deepcopy(saved.tags)
					vim.bo[buf].modified = false
				else
					vim.notify("Aero knowledge: " .. tostring(ok and err or saved), vim.log.levels.ERROR)
				end
			end,
		})
	end

	local win = require("aero.navigation").code_window()

	if win then
		vim.api.nvim_set_current_win(win)
	end

	vim.api.nvim_set_current_buf(buf)
	preview(buf, space_id)
	vim.notify("Tags for " .. initial.name .. ": one per line; :w to save; Enter to browse matching sources and notes")
	return buf
end

return M
