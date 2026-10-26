local M = {}
local storage = require("aero.storage")
local files = require("aero.tasks.storage")
local projections = {}
local refresh_note

local function directory(worktree)
	return vim.fs.joinpath(vim.fn.stdpath("data"), "Aero", "reading", storage.folder(storage.canonical(worktree)))
end

local function path(worktree, id)
	assert(type(id) == "string" and id:match("^[%w_-]+$"), "invalid reading list ID")
	return vim.fs.joinpath(directory(worktree), id .. ".json")
end

function M.load(worktree, id)
	local text = files.read(path(worktree, id))
	local ok, list = pcall(vim.json.decode, text or "")
	if ok and type(list) == "table" and type(list.items) == "table" then
		return list
	end
end

local function save(worktree, list)
	vim.fn.mkdir(directory(worktree), "p")
	local target = path(worktree, list.id)
	local tmp = target .. "." .. vim.fn.getpid() .. ".tmp"
	vim.fn.writefile({ vim.json.encode(list) }, tmp)
	assert(vim.uv.fs_rename(tmp, target))
	require("aero.events").emit("reading_changed", { worktree = worktree, id = list.id })
end

local function project(worktree, list, id)
	local items, count = {}, 0
	for _, item in ipairs(list.items) do
		count = count + (item.read and 1 or 0)
		table.insert(items, {
			filename = vim.fs.joinpath(worktree, item.path),
			lnum = item.lnum,
			end_lnum = item.end_lnum,
			text = (item.read and "[x] " or "[ ] ") .. item.label,
			user_data = { reading_item_id = item.id },
		})
	end
	local opts = {
		title = ("Aero: %s (%d/%d read)"):format(list.title, count, #items),
		context = { aero_reading = true, worktree = worktree, reading_list_id = list.id },
		items = items,
	}
	if id then
		opts.id = id
		opts.idx = vim.fn.getqflist({ id = id, idx = 0 }).idx
	end
	vim.fn.setqflist({}, id and "r" or " ", opts)
	local qid = id or vim.fn.getqflist({ id = 0 }).id
	projections[qid] = { worktree = worktree, id = list.id }
	if refresh_note then
		refresh_note()
	end
end

local function publish(binding, args, manual)
	local ok, result = pcall(function()
		assert(
			type(args.title) == "string" and args.title:match("%S") and not args.title:find("%c"),
			"title must be a nonempty single line"
		)
		assert(
			type(args.items) == "table"
				and vim.islist(args.items)
				and (manual or #args.items > 0)
				and #args.items <= 500,
			"provide up to 500 ordered items (agent lists must not be empty)"
		)
		local worktree = storage.canonical(binding.worktree)
		local id = args.id or files.id("reading")
		local previous = M.load(worktree, id)
		assert(manual or not previous or previous.session_key == binding.session_key, "list belongs to another session")
		local progress, seen, items = {}, {}, {}
		for _, item in ipairs(previous and previous.items or {}) do
			progress[item.id] = item.read
		end
		for _, item in ipairs(args.items) do
			assert(
				type(item.id) == "string" and item.id ~= "" and not seen[item.id],
				"item IDs must be nonempty and unique"
			)
			seen[item.id] = true
			assert(type(item.path) == "string" and item.path ~= "" and not item.path:find("%c"), "invalid source path")
			local source =
				storage.canonical(vim.startswith(item.path, "/") and item.path or vim.fs.joinpath(worktree, item.path))
			assert(
				storage.inside(source, worktree) and vim.fn.filereadable(source) == 1,
				"source must be an existing file in this worktree"
			)
			local lines = #vim.fn.readfile(source)
			assert(
				type(item.lnum) == "number"
					and item.lnum % 1 == 0
					and item.lnum >= 1
					and item.lnum <= math.max(1, lines),
				"invalid source line"
			)
			assert(
				item.end_lnum == nil
					or (
						type(item.end_lnum) == "number"
						and item.end_lnum % 1 == 0
						and item.end_lnum >= item.lnum
						and item.end_lnum <= lines
					),
				"invalid end line"
			)
			assert(
				type(item.label) == "string" and item.label:match("%S") and not item.label:find("%c"),
				"label must be a nonempty single line"
			)
			assert(item.note == nil or type(item.note) == "string", "note must be text")
			table.insert(items, {
				id = item.id,
				path = source:sub(#worktree + 2),
				lnum = item.lnum,
				end_lnum = item.end_lnum,
				label = item.label,
				note = item.note,
				read = progress[item.id] == true,
			})
		end
		local list = {
			id = id,
			title = args.title,
			session_key = previous and previous.session_key or binding.session_key,
			items = items,
		}
		save(worktree, list)
		for qid, ref in pairs(projections) do
			local context = vim.fn.getqflist({ id = qid, context = 0 }).context
			if type(context) ~= "table" or not context.aero_reading then
				projections[qid] = nil
			elseif ref.worktree == worktree and ref.id == id then
				project(worktree, list, qid)
			end
		end
		return { id = id, count = #items, message = "Saved. Open with :Aero reading" }
	end)
	if ok then
		return result
	end
	return nil, { code = "INVALID_ARGUMENT", message = tostring(result) }
end

function M.publish(binding, args)
	return publish(binding, args, false)
end

local function current_worktree()
	return storage.canonical(vim.t.aero_worktree or vim.fn.getcwd())
end

function M.list(worktree)
	local lists = {}
	if vim.fn.isdirectory(directory(worktree)) == 1 then
		for name, kind in vim.fs.dir(directory(worktree)) do
			if kind == "file" and name:match("%.json$") then
				local list = M.load(worktree, name:sub(1, -6))
				if list then
					table.insert(lists, list)
				end
			end
		end
	end
	table.sort(lists, function(a, b)
		return a.title == b.title and a.id < b.id or a.title < b.title
	end)
	return lists
end

local function pick(worktree, callback)
	local lists = M.list(worktree)
	if #lists == 0 then
		return vim.notify("Aero: no reading lists in this worktree; use :Aero reading new")
	end
	vim.ui.select(lists, {
		prompt = "Reading lists",
		format_item = function(list)
			return list.title
		end,
	}, function(list)
		if list then
			callback(list)
		end
	end)
end

local function editable(list)
	local document = { title = list.title, items = vim.deepcopy(list.items) }
	for _, item in ipairs(document.items) do
		item.read = nil
	end
	return document
end

local function document_lines(document)
	local lines = { "{", '  "title": ' .. vim.json.encode(document.title) .. ",", '  "items": [' }
	for i, item in ipairs(document.items) do
		table.insert(lines, "    " .. vim.json.encode(item) .. (i < #document.items and "," or ""))
	end
	vim.list_extend(lines, { "  ]", "}" })
	return lines
end

local function edit(worktree, list)
	local name = "Aero://reading/" .. storage.folder(worktree) .. "/" .. list.id
	local existing = vim.fn.bufnr(name)
	if existing ~= -1 then
		vim.cmd.sbuffer(existing)
		return
	end
	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_name(buf, name)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "json"
	local baseline = editable(list)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, document_lines(baseline))
	vim.bo[buf].modified = false
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			local latest = M.load(worktree, list.id)
			if not latest or not vim.deep_equal(editable(latest), baseline) then
				return vim.notify(
					"Aero: reading list changed since opening; reopen the editor before saving",
					vim.log.levels.ERROR
				)
			end
			local ok, args = pcall(vim.json.decode, table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
			if not ok or type(args) ~= "table" or type(args.items) ~= "table" then
				return vim.notify("Aero: expected JSON with title and items", vim.log.levels.ERROR)
			end
			for _, item in ipairs(args.items) do
				if type(item) == "table" and item.id == nil then
					item.id = files.id("step")
				end
			end
			args.id = list.id
			local result, err = publish({ worktree = worktree }, args, true)
			if not result then
				return vim.notify("Aero: " .. err.message, vim.log.levels.ERROR)
			end
			-- Keep newly generated IDs in the editable document for subsequent saves.
			baseline = editable(M.load(worktree, list.id))
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, document_lines(baseline))
			vim.bo[buf].modified = false
			vim.notify("Aero: reading list saved")
		end,
	})
	vim.cmd.split()
	vim.api.nvim_win_set_buf(0, buf)
end

local function add(worktree)
	local source = storage.canonical(vim.api.nvim_buf_get_name(0))
	local line = vim.api.nvim_win_get_cursor(0)[1]
	if vim.bo.buftype ~= "" or not storage.inside(source, worktree) or vim.fn.filereadable(source) ~= 1 then
		return vim.notify("Aero: add requires a saved source file in this worktree", vim.log.levels.WARN)
	end
	local default = vim.trim(vim.api.nvim_get_current_line())
	pick(worktree, function(list)
		vim.ui.input(
			{ prompt = "Reading item label: ", default = default ~= "" and default or vim.fs.basename(source) },
			function(label)
				if not label or vim.trim(label) == "" then
					return
				end
				-- Reload after the input so recent progress is retained.
				local latest = M.load(worktree, list.id)
				if not latest then
					return
				end
				table.insert(latest.items, { id = files.id("step"), path = source, lnum = line, label = label })
				local result, err = publish({ worktree = worktree }, latest, true)
				if not result then
					return vim.notify("Aero: " .. err.message, vim.log.levels.ERROR)
				end
				vim.notify("Aero: added to " .. latest.title)
			end
		)
	end)
end

local function selected()
	local qf = vim.fn.getqflist({ context = 0, idx = 0, id = 0, items = 0 })
	local ctx = qf.context
	if type(ctx) ~= "table" or not ctx.aero_reading then
		return
	end
	local list = M.load(ctx.worktree, ctx.reading_list_id)
	local index = vim.bo.buftype == "quickfix" and vim.fn.line(".") or qf.idx
	local entry = qf.items[index]
	for i, item in ipairs(list and list.items or {}) do
		if entry and type(entry.user_data) == "table" and item.id == entry.user_data.reading_item_id then
			return list, i, ctx.worktree, qf.id
		end
	end
end

-- Keep explanations separate from reader slots so source jumps never replace them.
refresh_note = function(open)
	local win = vim.t.aero_reading_note_win
	local visible = win and vim.api.nvim_win_is_valid(win)
	if not visible and not open then
		return
	end
	local list, index = selected()
	local lines = { "# Reading explanation", "", "Select an item in an Aero reading list." }
	if list then
		local item = list.items[index]
		lines = { "# " .. item.label, "", list.title, "", ("`%s:%d` "):format(item.path, item.lnum), "" }
		vim.list_extend(
			lines,
			vim.split(item.note or "No explanation was provided for this item.", "\n", { plain = true })
		)
	end
	if not visible then
		local buf = vim.api.nvim_create_buf(false, true)
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = "markdown"
		require("aero.layout").bind(buf)
		local position = require("aero.config").options.reading.explanation.position
		local anchor = require("aero.navigation").code_window("reading")
		local right = position == "right"
		win = vim.api.nvim_open_win(buf, false, {
			split = right and "right" or "below",
			win = anchor,
			width = right and 45 or nil,
			height = not right and 10 or nil,
		})
		vim.t.aero_reading_note_win = win
		vim.w[win].aero_reading_note = true
		vim.wo[win].wrap = true
		vim.wo[win].linebreak = true
		vim.wo[win].number = false
		vim.wo[win].relativenumber = false
		-- Let side-by-side reader panes share width when the agent panel opens.
		vim.wo[win].winfixwidth = false
		vim.wo[win].winfixheight = not right
		vim.wo[win].winbar = "Reading explanation"
		vim.keymap.set("n", "q", function()
			vim.api.nvim_win_close(win, true)
		end, { buffer = buf, desc = "Close reading explanation" })
		require("aero.layout").rebalance()
	end
	local buf = vim.api.nvim_win_get_buf(win)
	if not vim.deep_equal(vim.api.nvim_buf_get_lines(buf, 0, -1, false), lines) then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
	end
end

local note_group = vim.api.nvim_create_augroup("Aero.reading.notes", { clear = true })
vim.api.nvim_create_autocmd({ "CursorMoved", "BufEnter", "WinEnter", "QuickFixCmdPost" }, {
	group = note_group,
	callback = function()
		refresh_note()
	end,
})

local function jump(index, kind)
	local context = vim.fn.getqflist({ context = 0 }).context
	if type(context) == "table" and context.aero_reading then
		require("aero.reader").select(kind or "reading")
		local entry = vim.fn.getqflist()[index]
		if entry and entry.valid == 1 then
			vim.fn.setqflist({}, "a", { idx = index })
			vim.cmd("buffer " .. entry.bufnr)
			vim.api.nvim_win_set_cursor(0, { math.max(1, entry.lnum), math.max(0, entry.col - 1) })
			vim.cmd("normal! zv")
			refresh_note()
		end
		return
	end
	vim.cmd("cc " .. index)
end

function M.open(worktree, id)
	local list = M.load(worktree, id)
	if not list then
		return vim.notify("Aero: reading list no longer exists", vim.log.levels.WARN)
	end
	project(worktree, list)
	-- Native quickfix jumps use the window preceding :copen. In particular,
	-- an acwrite Source buffer (such as Oil) would otherwise force a split.
	require("aero.reader").select("reading")
	refresh_note(require("aero.config").options.reading.explanation.auto_open)
	vim.cmd.copen()
	require("aero.layout").bind(vim.api.nvim_get_current_buf())
	vim.keymap.set("n", "<CR>", function()
		jump(vim.fn.line("."))
	end, { buffer = true, desc = "Open reading item in reader" })
	vim.keymap.set("n", "x", function()
		M.command("toggle")
	end, { buffer = true, desc = "Toggle reading item" })
	vim.keymap.set("n", "K", function()
		M.command("note")
	end, { buffer = true, desc = "Reading item explanation" })
end

function M.command(action, worktree)
	worktree = worktree or current_worktree()
	if action == "note-toggle" then
		local win = vim.t.aero_reading_note_win
		if win and vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
			return
		end
		-- Opening still requires a selected reading item, like :Aero reading note.
		action = "note"
	end
	if action == "new" then
		return vim.ui.input({ prompt = "Reading list title: " }, function(title)
			if not title or vim.trim(title) == "" then
				return
			end
			local result, err = publish({ worktree = worktree }, { title = title, items = {} }, true)
			if not result then
				return vim.notify("Aero: " .. err.message, vim.log.levels.ERROR)
			end
			edit(worktree, M.load(worktree, result.id))
		end)
	elseif action == "add" then
		return add(worktree)
	elseif action == "edit" then
		return pick(worktree, function(list)
			edit(worktree, list)
		end)
	end
	if action then
		local list, index, worktree, qid = selected()
		if not list then
			return vim.notify("Aero: open a reading list first", vim.log.levels.WARN)
		end
		if action == "toggle" then
			list.items[index].read = not list.items[index].read
			save(worktree, list)
			project(worktree, list, qid)
		elseif action == "note" then
			refresh_note(true)
		elseif action == "source" then
			return jump(index, "source")
		elseif action == "next" then
			for offset = 1, #list.items do
				local next_index = (index + offset - 1) % #list.items + 1
				if not list.items[next_index].read then
					return jump(next_index)
				end
			end
			vim.notify("Aero: all items read")
		else
			vim.notify(
				"Aero: use :Aero reading [new|add|edit|next|source|toggle|note|note-toggle]",
				vim.log.levels.WARN
			)
		end
		return
	end
	pick(worktree, function(list)
		M.open(worktree, list.id)
	end)
end

return M
