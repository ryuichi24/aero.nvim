-- One acwrite buffer per state, coordinated by a single board editing session.
local api = vim.api
local tasks = require("aero.tasks")
local storage = require("aero.tasks.storage")
local edit = require("aero.tasks.edit")
local config = require("aero.config")
local M = {}
local sessions, active = {}, {}
local ns = api.nvim_create_namespace("Aero.tasks")
local diagnostics = api.nvim_create_namespace("Aero.tasks.edit")
local bind, layout, decorate

local function notify(message)
	vim.notify("Aero tasks: " .. tostring(message), vim.log.levels.WARN)
end

function M.current()
	return sessions[vim.b.aero_board_path] or active[api.nvim_get_current_tabpage()]
end

function M.dirty(view)
	for _, column in ipairs(view.columns or {}) do
		if not api.nvim_buf_is_valid(column.buf) or vim.bo[column.buf].modified then
			return true
		end
	end
	return false
end

-- Inspect retained buffers, including columns in hidden or closed tabs.
function M.status(board_path)
	local view = sessions[require("aero.storage").canonical(board_path)]
	local status = { dirty = false, stale = false, missing_column = false }
	if not view then
		return status
	end
	status.dirty = M.dirty(view)
	status.stale = storage.read(view.board.path) ~= view.baseline_text
	for _, column in ipairs(view.columns or {}) do
		if not api.nvim_buf_is_valid(column.buf) then
			status.missing_column = true
		end
	end
	return status
end

local function clean(view)
	if M.dirty(view) then
		notify("save all board edits with :w or discard with R first")
		return false
	end
	return true
end

local function selected(view)
	local buf = api.nvim_get_current_buf()
	for si, column in ipairs(view.columns) do
		if column.buf == buf then
			view.state_index = si
			view.ticket_index = api.nvim_win_get_cursor(0)[1]
			local id = api.nvim_get_current_line():match("^(%S+)  ")
			local item = id and view.registry[id]
			return item and item.entry, view.board.states[si]
		end
	end
	return nil, view.board.states[view.state_index or 1]
end

function M.selection()
	local view = M.current()
	if not view then
		return nil
	end
	local item, state = selected(view)
	return {
		workspace = view.board.ws,
		board_path = view.board.path,
		board_id = view.board.metadata and view.board.metadata.id,
		ticket_path = item and item.path,
		ticket_id = item and item.ticket and item.ticket.metadata and item.ticket.metadata.id,
		state = state and state.name,
	}
end

local function detail(item, state)
	if item.error then
		return "! " .. edit.title(item.error)
	end
	local data = item.ticket and item.ticket.metadata or {}
	local parts = {}
	if item.error then
		table.insert(parts, "! " .. item.error)
	end
	if data.priority then
		table.insert(parts, data.priority)
	end
	for _, name in ipairs(data.assignees or {}) do
		table.insert(parts, "@" .. name)
	end
	if data.due_date then
		local overdue = not vim.tbl_contains(config.options.tasks.terminal_states, state)
			and data.due_date < os.date("!%Y-%m-%d")
		table.insert(parts, (overdue and "OVERDUE " or "due ") .. data.due_date)
	end
	if data.estimate then
		table.insert(parts, data.estimate .. " " .. config.options.tasks.estimate_unit)
	end
	for _, tag in ipairs(data.tags or {}) do
		table.insert(parts, "#" .. tag)
	end
	return edit.title(table.concat(parts, " · "))
end

decorate = function(view, only)
	for _, column in ipairs(view.columns) do
		if api.nvim_buf_is_valid(column.buf) and (not only or only == column.buf) then
			api.nvim_buf_clear_namespace(column.buf, ns, 0, -1)
			local count = 0
			for row, line in ipairs(api.nvim_buf_get_lines(column.buf, 0, -1, false)) do
				if vim.trim(line) ~= "" then
					count = count + 1
				end
				local id = line:match("^(%S+)  ")
				local item = view.registry[id]
				if item then
					api.nvim_buf_set_extmark(column.buf, ns, row - 1, 0, {
						virt_text = { { detail(item.entry, column.name), "Comment" } },
						virt_text_pos = "eol",
					})
				end
			end
			for _, win in ipairs(vim.fn.win_findbuf(column.buf)) do
				vim.wo[win].conceallevel, vim.wo[win].concealcursor = 2, "nvic"
				local title = edit.title((view.board.metadata or {}).title or "Board")
				local archived = (view.board.metadata or {}).archived and " [archived]" or ""
				local errors = #view.board.diagnostics > 0 and " [diagnostics: g?]" or ""
				local recover_key = config.options.tasks.keymaps.recover
				local removed = #view.board.orphans > 0
						and (" · Removed tickets: " .. #view.board.orphans .. (recover_key and " (" .. recover_key .. ")" or ""))
					or ""
				vim.wo[win].winbar = (
					title
					.. archived
					.. " · "
					.. column.name
					.. " ("
					.. count
					.. ")"
					.. (view.stale and " [stale]" or "")
					.. errors
					.. removed
				):gsub("%%", "%%%%")
			end
		end
	end
end

function M.save(view)
	if view.saving then
		return
	end
	local columns, ticks, paths, titles = {}, {}, {}, {}
	for si, column in ipairs(view.columns) do
		if api.nvim_buf_is_valid(column.buf) then
			columns[si] = { name = column.name, lines = api.nvim_buf_get_lines(column.buf, 0, -1, false) }
			ticks[column.buf] = api.nvim_buf_get_changedtick(column.buf)
			vim.diagnostic.reset(diagnostics, column.buf)
		else
			columns[si] = { name = column.name }
		end
	end
	local states, errors, new_tickets, removed, restored = edit.parse(view.board.states, columns, view.registry)
	if #errors > 0 then
		local by_buffer, messages = {}, {}
		for _, err in ipairs(errors) do
			table.insert(messages, err.message)
			local col = err.state and view.columns[err.state]
			if col and api.nvim_buf_is_valid(col.buf) and err.row then
				by_buffer[col.buf] = by_buffer[col.buf] or {}
				table.insert(
					by_buffer[col.buf],
					{ lnum = err.row - 1, col = 0, message = err.message, severity = vim.diagnostic.severity.ERROR }
				)
			end
		end
		for buf, items in pairs(by_buffer) do
			vim.diagnostic.set(diagnostics, buf, items)
		end
		notify(table.concat(messages, "; "))
		return nil
	end
	for id, item in pairs(view.registry) do
		paths[id], titles[id] = item.entry.path, item.title
	end
	view.saving = true
	local ok, err, text, created = tasks.apply_layout(view.ws, view.path, {
		expected_text = view.baseline_text,
		states = states,
		paths = paths,
		titles = titles,
		new_tickets = new_tickets,
		removed_tickets = removed,
		restored_tickets = restored,
	})
	view.saving = false
	if not ok then
		view.stale = storage.read(view.path) ~= view.baseline_text
		decorate(view)
		notify(err)
		return nil
	end
	view.baseline_text, view.stale = text, false
	-- Add concealed identities to newly created rows only after the board commit succeeds.
	for si, column in ipairs(view.columns) do
		if api.nvim_buf_is_valid(column.buf) and api.nvim_buf_get_changedtick(column.buf) == ticks[column.buf] then
			local rows, changed = vim.deepcopy(columns[si].lines), false
			for key, ticket in pairs(created or {}) do
				local new = new_tickets[key]
				if new.state == si then
					rows[new.row] = ticket.metadata.id .. "  " .. edit.title(ticket.metadata.title)
					changed = true
				end
			end
			if changed then
				api.nvim_buf_call(column.buf, function()
					pcall(vim.cmd.undojoin)
					api.nvim_buf_set_lines(column.buf, 0, -1, false, rows)
				end)
				ticks[column.buf] = api.nvim_buf_get_changedtick(column.buf)
			end
		end
	end
	-- Refresh the committed model while retaining native column undo history.
	local board = tasks.read_board(view.ws, view.path)
	if board then
		view.board, view.registry = board, edit.registry(board)
	end
	for buf, tick in pairs(ticks) do
		if api.nvim_buf_is_valid(buf) and api.nvim_buf_get_changedtick(buf) == tick then
			vim.bo[buf].modified = false
		end
	end
	decorate(view)
	require("aero.dashboard").render()
	return true
end

local function conceal_identities(view, buf)
	api.nvim_buf_call(buf, function()
		vim.cmd("silent! syntax clear AeroTaskIdentity")
		vim.cmd([[syntax match AeroTaskIdentity /^task-[0-9a-f]\{20}  / conceal]])
		-- Custom frontmatter IDs remain supported, without concealing ordinary title words.
		for id in pairs(view.registry) do
			if not (id:match("^task%-%x+$") and #id == 25) then
				vim.cmd([[syntax match AeroTaskIdentity /^\V]] .. vim.fn.escape(id, [[\/]]) .. [[\m  / conceal]])
			end
		end
	end)
end

local function column_buffer(view, state)
	local buf = api.nvim_create_buf(true, false)
	vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "acwrite", "hide", false
	vim.bo[buf].filetype = "AeroBoard"
	-- Syntax conceal follows native edits/undo without rebuilding identity extmarks.
	conceal_identities(view, buf)
	api.nvim_buf_set_name(
		buf,
		"Aero://board/" .. vim.fn.sha256(view.path) .. "/" .. vim.fn.sha256(state.name):sub(1, 8)
	)
	vim.b[buf].aero_board_path, vim.b[buf].aero_workspace_root = view.path, view.ws.root
	api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			M.save(view)
		end,
	})
	api.nvim_create_autocmd("BufEnter", {
		buffer = buf,
		callback = function()
			active[api.nvim_get_current_tabpage()] = view
			decorate(view, buf)
		end,
	})
	-- Debounce decoration only: no filesystem work or whole-board parsing while typing.
	local generation = 0
	api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
		buffer = buf,
		callback = function()
			generation = generation + 1
			local current = generation
			vim.defer_fn(function()
				if generation == current and api.nvim_buf_is_valid(buf) then
					decorate(view, buf)
				end
			end, 80)
		end,
	})
	return buf
end

function M.render(view, discard, metadata_refresh)
	if vim.fn.getcmdwintype() ~= "" then
		return
	end
	if view.saving then
		return
	end
	local text = storage.read(view.path)
	if not discard and M.dirty(view) then
		view.stale = text ~= view.baseline_text
		if metadata_refresh then
			for _, registered in pairs(view.registry) do
				local item = registered.entry
				if item and item.path then
					local ticket = tasks.read_ticket(view.path, item.path)
					if ticket and ticket.valid then
						item.ticket = ticket
					end
				end
			end
		end
		decorate(view)
		return
	end
	if not discard and not metadata_refresh and text == view.baseline_text then
		return
	end
	local board, err = tasks.read_board(view.ws, view.path)
	if not board then
		notify(err)
		return
	end
	local old = {}
	local cursors = {}
	for _, column in ipairs(view.columns) do
		if api.nvim_buf_is_valid(column.buf) then
			for _, win in ipairs(vim.fn.win_findbuf(column.buf)) do
				local cursor = api.nvim_win_get_cursor(win)
				local line = api.nvim_buf_get_lines(column.buf, cursor[1] - 1, cursor[1], false)[1] or ""
				cursors[win] = { id = line:match("^(%S+)  "), row = cursor[1], col = cursor[2] }
			end
		end
	end
	for _, column in ipairs(view.columns) do
		old[column.name] = column
	end
	view.board, view.baseline_text, view.registry, view.stale = board, board.text, edit.registry(board), false
	view.columns = {}
	for si, state in ipairs(board.states) do
		local column = old[state.name]
		if not column or not api.nvim_buf_is_valid(column.buf) then
			column = { name = state.name, buf = column_buffer(view, state) }
		end
		old[state.name] = nil
		view.columns[si] = column
		conceal_identities(view, column.buf)
		local rows = edit.rows(state)
		if not vim.deep_equal(rows, api.nvim_buf_get_lines(column.buf, 0, -1, false)) then
			api.nvim_buf_set_lines(column.buf, 0, -1, false, rows)
		end
		vim.bo[column.buf].modified = false
		vim.diagnostic.reset(diagnostics, column.buf)
		bind(view, column)
	end
	for _, column in pairs(old) do
		if api.nvim_buf_is_valid(column.buf) then
			for _, win in ipairs(vim.fn.win_findbuf(column.buf)) do
				if view.columns[1] then
					api.nvim_win_set_buf(win, view.columns[1].buf)
				end
			end
			api.nvim_buf_delete(column.buf, { force = true })
		end
	end
	view.buf = view.columns[1] and view.columns[1].buf
	for win, cursor in pairs(cursors) do
		if api.nvim_win_is_valid(win) then
			local buf = api.nvim_win_get_buf(win)
			local rows = api.nvim_buf_get_lines(buf, 0, -1, false)
			local row = math.min(cursor.row, #rows)
			for index, line in ipairs(rows) do
				if cursor.id and line:match("^(%S+)  ") == cursor.id then
					row = index
					break
				end
			end
			api.nvim_win_set_cursor(win, { math.max(1, row), math.min(cursor.col, #(rows[row] or "")) })
		end
	end
	decorate(view)
end

local function geometry(view)
	local dimensions = { vim.o.columns, vim.o.lines }
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		for _, column in ipairs(view.columns) do
			if api.nvim_win_get_buf(win) == column.buf then
				vim.list_extend(dimensions, { win, api.nvim_win_get_width(win), api.nvim_win_get_height(win) })
				break
			end
		end
	end
	return table.concat(dimensions, ":")
end

-- Only manipulate windows owned by this board in the current tab.
layout = function(view, focus, resized)
	if vim.fn.getcmdwintype() ~= "" then
		return
	end
	if #view.columns == 0 then
		notify("board has no states; edit its source")
		return
	end
	local wins, width = {}, 0
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		local buf = api.nvim_win_get_buf(win)
		for _, column in ipairs(view.columns) do
			if column.buf == buf then
				table.insert(wins, win)
				width = width + api.nvim_win_get_width(win) + 1
				break
			end
		end
	end
	if #wins == 0 then
		local win = api.nvim_get_current_win()
		api.nvim_win_set_buf(win, view.columns[1].buf)
		wins, width = { win }, api.nvim_win_get_width(win)
	end
	-- Dedicated board-only tabs own the full editor width, even before Neovim has
	-- redistributed the existing splits following an external screen resize.
	local normal_windows = 0
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if api.nvim_win_get_config(win).relative == "" then
			normal_windows = normal_windows + 1
		end
	end
	if #wins == normal_windows then
		width = vim.o.columns
	end
	local count =
		math.max(1, math.min(#view.columns, math.floor(width / math.max(12, config.options.tasks.column_width))))
	focus = math.max(1, math.min(focus or 1, #view.columns))
	local tab = api.nvim_get_current_tabpage()
	local target
	for _, column in ipairs(view.columns) do
		column.cursors = column.cursors or {}
		for _, win in ipairs(wins) do
			if api.nvim_win_get_buf(win) == column.buf then
				column.cursors[tab] = api.nvim_win_get_cursor(win)
				if column == view.columns[focus] then
					target = win
				end
			end
		end
	end
	if target and #wins == count then
		for _, win in ipairs(wins) do
			vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false
			if resized then
				pcall(api.nvim_win_set_width, win, math.max(1, math.floor(width / count) - 1))
			end
		end
		api.nvim_set_current_win(target)
		decorate(view)
		view.geometry = geometry(view)
		return
	end
	local first = math.max(1, math.min(focus, #view.columns - count + 1))
	local anchor = wins[1]
	for i = #wins, 2, -1 do
		api.nvim_win_close(wins[i], true)
	end
	api.nvim_win_set_buf(anchor, view.columns[first].buf)
	local displayed = { anchor }
	for offset = 1, count - 1 do
		local win =
			api.nvim_open_win(view.columns[first + offset].buf, false, { split = "right", win = displayed[#displayed] })
		table.insert(displayed, win)
	end
	for index, win in ipairs(displayed) do
		vim.wo[win].wrap, vim.wo[win].number, vim.wo[win].relativenumber = false, false, false
		pcall(api.nvim_win_set_width, win, math.max(1, math.floor(width / count) - 1))
		local cursor = view.columns[first + index - 1].cursors[tab]
		if cursor then
			pcall(api.nvim_win_set_cursor, win, cursor)
		end
	end
	api.nvim_set_current_win(displayed[focus - first + 1])
	decorate(view)
	view.geometry = geometry(view)
end

local function ticket_float_config(title)
	local width = math.max(1, math.min(math.floor(vim.o.columns * 0.8), vim.o.columns - 4))
	local height = math.max(1, math.min(math.floor(vim.o.lines * 0.8), vim.o.lines - 6))
	return {
		relative = "editor",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2) - 1),
		border = "rounded",
		title = " " .. edit.title(title) .. " ",
		title_pos = "center",
	}
end

local function open_file(view, path)
	if not path then
		notify("invalid ticket reference; fix the board source first")
		return
	end
	local doc, err
	if path == view.path then
		doc, err = tasks.read_board(view.ws, path)
	else
		doc, err = tasks.read_ticket(view.path, path)
	end
	if not doc then
		notify(err)
		return
	end
	if path ~= view.path then
		local buf = vim.fn.bufadd(path)
		vim.fn.bufload(buf)
		local title = doc.metadata and doc.metadata.title or vim.fs.basename(path)
		local win = view.ticket_window
		if win and api.nvim_win_is_valid(win) then
			api.nvim_set_current_win(win)
			-- Use :buffer so a different unsaved ticket is not silently abandoned.
			local ok, buffer_err = pcall(vim.cmd.buffer, buf)
			if not ok then
				notify(buffer_err)
				return
			end
			api.nvim_win_set_config(win, ticket_float_config(title))
		else
			win = api.nvim_open_win(buf, true, ticket_float_config(title))
			view.ticket_window = win
		end
		vim.bo[buf].filetype = "markdown"
		vim.b[buf].aero_board_path, vim.b[buf].aero_workspace_root = view.path, view.ws.root
		vim.wo[win].winbar = ""
		vim.wo[win].wrap = true
		vim.wo[win].conceallevel, vim.wo[win].concealcursor = vim.o.conceallevel, vim.o.concealcursor
		return
	end
	-- Use a separate code split so column windows continue to represent states.
	view.file_windows = view.file_windows or {}
	local tab = api.nvim_get_current_tabpage()
	local win = view.file_windows[tab]
	if win and api.nvim_win_is_valid(win) then
		for _, column in ipairs(view.columns) do
			if api.nvim_win_get_buf(win) == column.buf then
				win = nil
				break
			end
		end
	end
	if not win or not api.nvim_win_is_valid(win) then
		local anchor = api.nvim_get_current_win()
		if api.nvim_win_get_config(anchor).relative ~= "" then
			for _, candidate in ipairs(api.nvim_tabpage_list_wins(0)) do
				if api.nvim_win_get_config(candidate).relative == "" then
					anchor = candidate
					break
				end
			end
		end
		win = api.nvim_open_win(api.nvim_create_buf(false, true), true, { split = "below", win = anchor })
		view.file_windows[tab] = win
	else
		api.nvim_set_current_win(win)
	end
	api.nvim_win_call(win, function()
		vim.cmd.edit(vim.fn.fnameescape(path))
	end)
	vim.wo[win].conceallevel, vim.wo[win].concealcursor = vim.o.conceallevel, vim.o.concealcursor
	vim.b.aero_board_path, vim.b.aero_workspace_root = view.path, view.ws.root
end

function M.new_ticket(view)
	view = view or M.current()
	if not view then
		notify("open a board first")
		return
	end
	if not clean(view) then
		return
	end
	local _, state = selected(view)
	if not state then
		notify("add a state in the source board first")
		return
	end
	vim.ui.input({ prompt = "New ticket title: " }, function(name)
		if not name or vim.trim(name) == "" or not clean(view) then
			return
		end
		local ok, err = tasks.create_ticket(view.ws, view.path, state.name, vim.trim(name))
		if not ok then
			notify(err)
			return
		end
		M.render(view)
		decorate(view)
		require("aero.dashboard").render()
	end)
end

local function move_row(view, target, position)
	local item, state = selected(view)
	if not item then
		notify("select a ticket first")
		return
	end
	local source = view.columns[view.state_index]
	local destination
	for _, column in ipairs(view.columns) do
		if column.name == target then
			destination = column
		end
	end
	if not destination or not api.nvim_buf_is_valid(destination.buf) then
		notify("missing state buffer")
		return
	end
	local row = api.nvim_win_get_cursor(0)[1]
	local raw = api.nvim_get_current_line()
	api.nvim_buf_set_lines(source.buf, row - 1, row, false, {})
	local lines = api.nvim_buf_get_lines(destination.buf, 0, -1, false)
	if #lines == 1 and lines[1] == "" then
		lines = {}
	end
	table.insert(lines, math.min(position or #lines + 1, #lines + 1), raw)
	api.nvim_buf_set_lines(destination.buf, 0, -1, false, lines)
	decorate(view)
end

function M.move(view)
	view = view or M.current()
	if not view then
		notify("open a board first")
		return
	end
	if not selected(view) then
		notify("select a ticket first")
		return
	end
	vim.ui.select(
		vim.tbl_map(function(s)
			return s.name
		end, view.board.states),
		{ prompt = "Move ticket to state (save with :w)" },
		function(name)
			if name then
				move_row(view, name)
			end
		end
	)
end

function M.actions(view)
	local function apply(fn, ...)
		if not clean(view) then
			return
		end
		local ok, err = fn(view.ws, view.path, ...)
		if not ok then
			notify(err)
			return
		end
		M.render(view)
		layout(view, view.state_index)
		require("aero.dashboard").render()
	end
	local function navigation(ds, dt)
		selected(view)
		if ds ~= 0 then
			layout(view, (view.state_index or 1) + ds)
		else
			api.nvim_win_set_cursor(
				0,
				{ math.max(1, math.min(api.nvim_buf_line_count(0), api.nvim_win_get_cursor(0)[1] + dt)), 0 }
			)
		end
	end
	return {
		open = function()
			local item = selected(view)
			if item then
				open_file(view, item.path)
			end
		end,
		source = function()
			open_file(view, view.path)
		end,
		new = function()
			M.new_ticket(view)
		end,
		move = function()
			M.move(view)
		end,
		work = function()
			require("aero.tasks.agent").work()
		end,
		rename = function()
			if not clean(view) then
				return
			end
			local item = selected(view)
			local data = item and item.ticket and item.ticket.metadata or view.board.metadata or {}
			vim.ui.input({ prompt = "Rename: ", default = data.title }, function(value)
				if value and vim.trim(value) ~= "" then
					apply(tasks.update_metadata, item and item.path, { title = vim.trim(value) })
				end
			end)
		end,
		remove = function()
			if not clean(view) then
				return
			end
			local item = selected(view)
			if item and vim.fn.confirm("Remove ticket reference? (file is kept)", "&Yes\n&No", 2) == 1 then
				apply(tasks.remove_ticket, item.path, false)
			end
		end,
		delete = function()
			if not clean(view) then
				return
			end
			local item = selected(view)
			if item and vim.fn.confirm("Permanently delete ticket file?", "&Yes\n&No", 2) == 1 then
				apply(tasks.remove_ticket, item.path, true)
			end
		end,
		archive = function()
			apply(tasks.archive_board, not (view.board.metadata or {}).archived)
		end,
		metadata = function()
			if not clean(view) then
				return
			end
			local item = selected(view)
			local fields = item and { "title", "task_type", "priority", "assignees", "tags", "due_date", "estimate" }
				or { "title", "description", "tags", "archived" }
			local data = item and item.ticket and item.ticket.metadata or view.board.metadata or {}
			vim.ui.select(fields, { prompt = "Edit metadata" }, function(field)
				if not field then
					return
				end
				vim.ui.input({
					prompt = field .. " (JSON value): ",
					default = data[field] ~= nil and vim.json.encode(data[field]) or "",
				}, function(value)
					if not value or value == "" then
						return
					end
					local ok, decoded = pcall(vim.json.decode, value)
					if not ok then
						notify("enter a JSON value")
						return
					end
					apply(tasks.update_metadata, item and item.path, { [field] = decoded })
				end)
			end)
		end,
		states = function()
			if not clean(view) then
				return
			end
			local _, state = selected(view)
			vim.ui.select({ "Add", "Rename", "Reorder", "Remove" }, { prompt = "Manage states" }, function(action)
				if action == "Add" or action == "Rename" and state then
					vim.ui.input(
						{ prompt = action .. " state: ", default = action == "Rename" and state.name or "" },
						function(name)
							if name and name ~= "" then
								if action == "Add" then
									apply(tasks.add_state, name)
								else
									apply(tasks.rename_state, state.name, name)
								end
							end
						end
					)
				elseif action == "Reorder" and state then
					vim.ui.input({ prompt = "State position: " }, function(value)
						if tonumber(value) then
							apply(tasks.reorder_state, state.name, tonumber(value))
						end
					end)
				elseif action == "Remove" and state then
					if #state.entries == 0 then
						apply(tasks.remove_state, state.name)
					else
						local names = {}
						for _, s in ipairs(view.board.states) do
							if s.name ~= state.name then
								table.insert(names, s.name)
							end
						end
						vim.ui.select(names, { prompt = "Move tickets before removing state" }, function(name)
							if name then
								apply(tasks.remove_state, state.name, name)
							end
						end)
					end
				end
			end)
		end,
		recover = function()
			if not clean(view) then
				return
			end
			return require("aero.tasks.ui").removed(view.ws, view.path)
		end,
		earlier = function()
			local item, state = selected(view)
			if item then
				move_row(view, state.name, math.max(1, view.ticket_index - 1))
			end
		end,
		later = function()
			local item, state = selected(view)
			if item then
				move_row(view, state.name, view.ticket_index + 1)
			end
		end,
		previous = function()
			navigation(-1, 0)
		end,
		next = function()
			navigation(1, 0)
		end,
		up = function()
			navigation(0, -1)
		end,
		down = function()
			navigation(0, 1)
		end,
		refresh = function()
			if M.dirty(view) and vim.fn.confirm("Discard ALL board column edits and reload?", "&Yes\n&No", 2) ~= 1 then
				return
			end
			M.render(view, true)
			layout(view, view.state_index)
		end,
		help = function()
			local lines =
				{ "Type a new title to create a ticket; dd/p moves rows. :w saves ALL columns. Undo is column-local." }
			local data = view.board.metadata or {}
			if data.description then
				table.insert(lines, edit.title(data.description))
			end
			if type(data.tags) == "table" and vim.islist(data.tags) then
				table.insert(lines, "Tags: " .. table.concat(data.tags, ", "))
			end
			for name, key in pairs(config.options.tasks.keymaps) do
				if key then
					table.insert(lines, key .. "  " .. name)
				end
			end
			vim.list_extend(lines, view.board.diagnostics)
			vim.notify(table.concat(lines, "\n"))
		end,
		close = function()
			if not clean(view) then
				return
			end
			if view.tab and api.nvim_tabpage_is_valid(view.tab) then
				api.nvim_set_current_tabpage(view.tab)
				-- No force: modified ticket/source buffers retain normal tab-close protection.
				vim.cmd.tabclose()
				view.tab = nil
				if view.origin_tab and api.nvim_tabpage_is_valid(view.origin_tab) then
					api.nvim_set_current_tabpage(view.origin_tab)
				end
				return
			end
			local windows = {}
			for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
				for _, column in ipairs(view.columns) do
					if api.nvim_win_get_buf(win) == column.buf then
						table.insert(windows, win)
						break
					end
				end
			end
			if #windows > 0 then
				api.nvim_set_current_win(windows[1])
				vim.cmd.edit(vim.fn.fnameescape(view.path))
				vim.wo.conceallevel, vim.wo.concealcursor = vim.o.conceallevel, vim.o.concealcursor
				for i = 2, #windows do
					api.nvim_win_close(windows[i], true)
				end
			end
		end,
	}
end

bind = function(view, column)
	for _, binding in ipairs(column.bindings or {}) do
		api.nvim_buf_call(column.buf, function()
			if vim.fn.maparg(binding.key, "n", false, true).callback == binding.fn then
				vim.keymap.del("n", binding.key, { buffer = column.buf })
			end
		end)
	end
	column.bindings = {}
	for name, fn in pairs(M.actions(view)) do
		local key = config.options.tasks.keymaps[name]
		if key then
			vim.keymap.set(
				"n",
				key,
				fn,
				{ buffer = column.buf, silent = true, nowait = true, desc = "Aero tasks: " .. name }
			)
			table.insert(column.bindings, { key = key, fn = fn })
		end
	end
end

function M.setup()
	for _, view in pairs(sessions) do
		for _, column in ipairs(view.columns) do
			if api.nvim_buf_is_valid(column.buf) then
				bind(view, column)
			end
		end
	end
end

function M.open(ws, path)
	path = require("aero.storage").canonical(path)
	local view = sessions[path]
	if not view then
		view = { ws = ws, path = path, columns = {}, state_index = 1, ticket_index = 1 }
		sessions[path] = view
	end
	M.render(view)
	if not view.board then
		sessions[path] = nil
		return
	end
	if #view.columns == 0 then
		notify("board has no states; edit its source")
		return
	end
	if view.tab and api.nvim_tabpage_is_valid(view.tab) then
		api.nvim_set_current_tabpage(view.tab)
	else
		view.origin_tab = api.nvim_get_current_tabpage()
		vim.cmd.tabnew()
		view.tab = api.nvim_get_current_tabpage()
		vim.t.aero_board_path = view.path
	end
	active[api.nvim_get_current_tabpage()] = view
	layout(view, view.state_index)
	return view
end

local group = api.nvim_create_augroup("Aero.tasks", { clear = true })
api.nvim_create_autocmd("User", {
	group = group,
	pattern = "AeroTaskChanged",
	callback = function(event)
		if vim.fn.getcmdwintype() ~= "" then
			return
		end
		local view = event.data and sessions[event.data.board_path]
		if view then
			M.render(view, false, true)
		end
		require("aero.dashboard").render()
	end,
})
local pending, metadata_refresh = false, false
api.nvim_create_autocmd({ "BufWritePost", "FocusGained", "CmdwinLeave" }, {
	group = group,
	callback = function(event)
		metadata_refresh = metadata_refresh
			or event.event == "BufWritePost"
			or event.event == "FocusGained"
			or event.event == "CmdwinLeave"
		if pending then
			return
		end
		pending = true
		vim.schedule(function()
			pending = false
			local reload = metadata_refresh
			metadata_refresh = false
			for _, view in pairs(sessions) do
				M.render(view, false, reload)
			end
			require("aero.dashboard").render()
		end)
	end,
})
local resize_pending = false
api.nvim_create_autocmd({ "VimResized", "WinResized", "TabEnter", "CmdwinLeave" }, {
	group = group,
	callback = function()
		if resize_pending then
			return
		end
		resize_pending = true
		vim.schedule(function()
			resize_pending = false
			-- q: / q/ prohibit switching, opening, or closing other windows (E11).
			-- CmdwinLeave retries any deferred reflow once normal window access resumes.
			if vim.fn.getcmdwintype() ~= "" then
				return
			end
			local tab = api.nvim_get_current_tabpage()
			for _, view in pairs(sessions) do
				if view.tab == tab and view.ticket_window and api.nvim_win_is_valid(view.ticket_window) then
					local win = view.ticket_window
					local title = api.nvim_win_get_config(win).title
					local options = ticket_float_config("")
					options.title = title
					api.nvim_win_set_config(win, options)
				end
				-- Reflow only the displayed board. TabEnter catches inactive-tab resizes.
				if view.tab == tab and view.geometry ~= geometry(view) then
					local focused = api.nvim_get_current_win()
					local is_column, visible, valid = false, false, true
					for _, column in ipairs(view.columns) do
						valid = valid and api.nvim_buf_is_valid(column.buf)
						for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
							if api.nvim_win_get_buf(win) == column.buf then
								visible = true
								if win == focused then
									is_column = true
								end
							end
						end
					end
					if visible and valid then
						selected(view)
						layout(view, view.state_index, true)
						if not is_column and api.nvim_win_is_valid(focused) then
							api.nvim_set_current_win(focused)
						end
					end
				end
			end
		end)
	end,
})

return M
