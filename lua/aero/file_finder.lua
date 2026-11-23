-- Oil-style navigation with explicit, save-to-stage copy/cut operations.
local api = vim.api
local M = {}
local active
local namespace = api.nvim_create_namespace("aero_file_finder")

local function warn(err)
	vim.notify("Aero: " .. tostring(err), vim.log.levels.WARN)
end

-- transfer(items) returns true on success, or nil, error to keep the finder open.
-- Items contain path/action (copy or cut); callbacks may mark items done for retries.
function M.open(options)
	assert(
		type(options.transfer) == "function" or type(options.select) == "function",
		"file finder requires a callback"
	)
	local target_key = assert(options.target_key, "file finder requires a target key")

	if active then
		if active.target_key ~= target_key then
			warn("finish the current finder before switching import targets")
		end

		if api.nvim_win_is_valid(active.win) then
			api.nvim_set_current_win(active.win)
		end

		return active
	end

	local home = vim.fn.expand(options.home or "~")

	if vim.fn.isdirectory(home) ~= 1 then
		return warn("finder home is not a directory: " .. home)
	end

	vim.cmd.stopinsert()
	local f = {
		target_key = target_key,
		directory = vim.fs.normalize(vim.fn.fnamemodify(home, ":p")),
		pending = {},
		staged = {},
	}
	local target_label = (options.target_label or target_key):gsub("[%c]", " ")
	local target_path = (options.target_path or target_label):gsub("[%c]", " ")
	local target_kind = options.target_kind or "Target"
	local finder_title = " " .. (options.title or "File finder") .. " · target: " .. target_label .. " "
	local previous = api.nvim_get_current_win()
	f.buf = api.nvim_create_buf(false, true)
	f.stack = api.nvim_create_buf(false, true)
	vim.bo[f.buf].buftype = "acwrite"
	vim.bo[f.buf].swapfile = false
	vim.bo[f.buf].bufhidden = "hide"
	vim.bo[f.buf].filetype = options.filetype or "aero_file_finder"
	api.nvim_buf_set_name(f.buf, "aero-file-finder://" .. f.buf)

	local function geometry()
		local width = math.max(1, vim.o.columns - 6)
		local height = math.max(2, vim.o.lines - 8)
		local stack_height = math.max(1, math.min(8, math.floor(height / 3)))
		return width, height - stack_height - 2, stack_height
	end

	local width, height, stack_height = geometry()
	f.win = api.nvim_open_win(f.buf, true, {
		relative = "editor",
		row = 1,
		col = 2,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		title = finder_title,
		footer = " " .. target_kind .. ": " .. target_path .. " ",
	})
	f.stack_win = api.nvim_open_win(f.stack, false, {
		relative = "editor",
		row = height + 3,
		col = 2,
		width = width,
		height = stack_height,
		style = "minimal",
		border = "rounded",
		title = " " .. (options.stack_title or "Staged files") .. " → " .. target_label .. " ",
		focusable = false,
		footer = options.select and " y: stage · u: unstage · :w: rename · q: finish · n: new Git folder "
			or " :w to stage · q to finish · target: " .. target_path .. " ",
	})
	active = f
	vim.wo[f.win].cursorline = true
	vim.wo[f.win].wrap = false
	vim.wo[f.stack_win].wrap = false

	local function set_lines(buf, lines)
		vim.bo[buf].modifiable = true
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = false
	end

	local function stack()
		local lines = {}

		for _, item in ipairs(f.staged) do
			table.insert(
				lines,
				"  " .. item.action .. "  " .. (options.label and options.label(item.path) or item.path)
			)
		end

		if #lines == 0 then
			lines = options.empty_hint and { options.empty_hint }
				or options.select and {
					"  Yank Git folders with y, then q to add staged workspaces. Enter/l: enter · -/h: parent",
				}
				or { "  No staged items. y: copy · d: cut · u: unmark · Enter/l: enter · -/h: parent" }
		end

		set_lines(f.stack, lines)
		api.nvim_win_set_cursor(f.stack_win, { #lines, 0 })
	end

	local function render()
		if options.entries then
			f.entries = options.entries
		else
			local scan, err = vim.uv.fs_scandir(f.directory)

			if not scan then
				return warn(err)
			end

			f.entries = {}
			while true do
				local name, kind = vim.uv.fs_scandir_next(scan)

				if not name then
					break
				end

				local path = vim.fs.joinpath(f.directory, name)

				if kind == "link" and vim.fn.isdirectory(path) == 1 then
					kind = "directory"
				end

				if not options.select or kind == "directory" then
					table.insert(f.entries, { name = name, path = path, kind = kind })
				end
			end
			table.sort(f.entries, function(a, b)
				if (a.kind == "directory") ~= (b.kind == "directory") then
					return a.kind == "directory"
				end

				return a.name < b.name
			end)
		end

		local lines = {}

		for _, item in ipairs(f.entries) do
			local mark = f.pending[item.path]
			table.insert(
				lines,
				(mark and (mark == "cut" and "d " or "y ") or "  ")
					.. item.name:gsub("[%c]", "?")
					.. (item.kind == "directory" and "/" or "")
			)
		end

		set_lines(f.buf, lines)
		f.rendered = lines
		vim.bo[f.buf].modifiable = options.rename ~= nil
		api.nvim_buf_clear_namespace(f.buf, namespace, 0, -1)

		if options.highlight then
			for row, item in ipairs(f.entries) do
				local group = options.highlight(item.path)

				if group then
					api.nvim_buf_set_extmark(f.buf, namespace, row - 1, 2, {
						end_col = #lines[row],
						hl_group = group,
					})
				end
			end
		end

		vim.bo[f.buf].modified = next(f.pending) ~= nil or (options.select ~= nil and #f.staged > 0)
		api.nvim_win_set_config(f.win, {
			title = finder_title .. (options.entries and "" or "· browsing: " .. f.directory:gsub("[%c]", " ") .. " "),
		})
	end

	local function edited()
		return options.rename and not vim.deep_equal(api.nvim_buf_get_lines(f.buf, 0, -1, false), f.rendered)
	end

	local function require_saved()
		if edited() then
			warn("write folder name changes with :w before continuing")
			return false
		end

		return true
	end

	local function save()
		if options.rename and edited() then
			local lines = api.nvim_buf_get_lines(f.buf, 0, -1, false)

			if #lines ~= #f.rendered then
				return warn("rename folders in place; do not add or remove lines")
			end

			local changes, targets = {}, {}

			for row, line in ipairs(lines) do
				local item = f.entries[row]
				local name = line:match("^  (.-)/$")

				if not name or name == "" or name == "." or name == ".." or name:find("[/\\%c]") then
					return warn("each line must contain a single folder name with its original prefix and trailing /")
				end

				local path = vim.fs.joinpath(f.directory, name)

				if targets[path] or (path ~= item.path and vim.uv.fs_lstat(path)) then
					return warn("folder already exists: " .. path)
				end

				targets[path] = true

				if line ~= f.rendered[row] then
					table.insert(changes, { item = item, path = path, row = row, name = name })
				end
			end

			for _, change in ipairs(changes) do
				local old = change.item.path
				local ok, err = options.rename(old, change.path)

				if not ok then
					return warn(err)
				end

				for _, staged in ipairs(f.staged) do
					if staged.path == old or vim.startswith(staged.path, old .. "/") then
						staged.path = change.path .. staged.path:sub(#old + 1)
					end
				end

				change.item.path, change.item.name = change.path, change.name
				f.rendered[change.row] = lines[change.row]
			end
		end

		for path, action in pairs(f.pending) do
			local found

			for _, item in ipairs(f.staged) do
				if item.path == path then
					item.action, found = action, true
				end
			end

			if not found then
				table.insert(f.staged, { path = path, action = action })
			end
		end

		table.sort(f.staged, function(a, b)
			return a.path < b.path
		end)
		f.pending = {}
		stack()
		render()
	end

	local closing = false
	local watch_close

	local function finish(external)
		if closing then
			return
		end

		if not external and not require_saved() then
			return
		end

		if options.select and not external then
			f.staged = vim.tbl_filter(function(item)
				return not options.select(item.path)
			end, f.staged)
			stack()
			render()

			if #f.staged > 0 then
				return
			end
		end

		local remaining = vim.tbl_filter(function(item)
			return not item.done
		end, f.staged)
		local ok, result, err = true, true, nil

		if options.transfer then
			ok, result, err = pcall(options.transfer, remaining)
		end

		if not ok or not result then
			warn(ok and err or result)

			if external then
				local w, h = geometry()
				f.win = api.nvim_open_win(f.buf, true, {
					relative = "editor",
					row = 1,
					col = 2,
					width = w,
					height = h,
					style = "minimal",
					border = "rounded",
					title = finder_title .. "· resolve transfer error and retry q ",
					footer = " " .. target_kind .. ": " .. target_path .. " ",
				})
				watch_close()
			end

			return
		end

		closing = true
		active = nil

		for _, win in ipairs({ f.stack_win, f.win }) do
			if api.nvim_win_is_valid(win) then
				api.nvim_win_close(win, true)
			end
		end

		for _, buf in ipairs({ f.buf, f.stack }) do
			if api.nvim_buf_is_valid(buf) then
				api.nvim_buf_delete(buf, { force = true })
			end
		end

		if api.nvim_win_is_valid(previous) then
			api.nvim_set_current_win(previous)
		end
	end

	local function mark(action)
		if not require_saved() then
			return
		end

		local first, last = api.nvim_win_get_cursor(f.win)[1], api.nvim_win_get_cursor(f.win)[1]

		if vim.fn.mode():match("[vV]") then
			first, last = vim.fn.line("v"), vim.fn.line(".")

			if first > last then
				first, last = last, first
			end

			api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
		end

		for row = first, last do
			local item = f.entries[row]

			if item then
				f.pending[item.path] = action

				if not action then
					f.staged = vim.tbl_filter(function(staged)
						return staged.path ~= item.path
					end, f.staged)
				end
			end
		end

		if options.select then
			for path, pending_action in pairs(f.pending) do
				local found = false

				for _, item in ipairs(f.staged) do
					found = found or item.path == path
				end

				if not found then
					table.insert(f.staged, { path = path, action = pending_action })
				end
			end

			f.pending = {}
		end

		stack()
		render()

		if options.select then
			vim.bo[f.buf].modified = #f.staged > 0
		end
	end

	for key, action in
		pairs(
			(options.select or options.copy_only) and { y = "copy", u = false } or { y = "copy", d = "cut", u = false }
		)
	do
		vim.keymap.set({ "n", "x" }, key, function()
			mark(action or nil)
		end, { buffer = f.buf, nowait = true })
	end

	if options.select then
		vim.keymap.set("n", "n", function()
			if not require_saved() then
				return
			end

			local directory = f.directory
			vim.ui.input({ prompt = "New Git folder: " }, function(name)
				if active ~= f or not name or name == "" then
					return
				end

				local path, err = options.create(directory, name)

				if not path then
					return warn(err)
				end

				f.directory = path
				render()
			end)
		end, { buffer = f.buf, desc = "Create Git folder" })
	end

	for _, key in ipairs({ "<CR>", "l" }) do
		vim.keymap.set("n", key, function()
			if options.entries then
				return
			end

			if not require_saved() then
				return
			end

			local item = f.entries[api.nvim_win_get_cursor(f.win)[1]]

			if item and vim.fn.isdirectory(item.path) == 1 then
				f.directory = item.path
				render()
			end
		end, { buffer = f.buf })
	end

	for _, key in ipairs({ "-", "h" }) do
		vim.keymap.set("n", key, function()
			if options.entries then
				return
			end

			if not require_saved() then
				return
			end

			local child = f.directory
			f.directory = vim.fs.dirname(child) or child
			render()

			for row, item in ipairs(f.entries) do
				if vim.fs.normalize(item.path) == vim.fs.normalize(child) then
					api.nvim_win_set_cursor(f.win, { row, 0 })
					break
				end
			end
		end, { buffer = f.buf })
	end

	for _, key in ipairs({ "q", "<Esc>" }) do
		vim.keymap.set("n", key, function()
			finish(false)
		end, { buffer = f.buf })
	end

	api.nvim_create_autocmd("BufWriteCmd", { buffer = f.buf, callback = save })
	watch_close = function()
		api.nvim_create_autocmd("WinClosed", {
			pattern = tostring(f.win),
			once = true,
			callback = function()
				vim.schedule(function()
					finish(true)
				end)
			end,
		})
	end
	watch_close()
	local resize = api.nvim_create_autocmd("VimResized", {
		callback = function()
			if active ~= f then
				return
			end

			local w, h, sh = geometry()
			api.nvim_win_set_config(f.win, { width = w, height = h })
			api.nvim_win_set_config(f.stack_win, { width = w, height = sh, row = h + 3 })
		end,
	})
	api.nvim_create_autocmd("BufWipeout", {
		buffer = f.buf,
		once = true,
		callback = function()
			pcall(api.nvim_del_autocmd, resize)
		end,
	})
	stack()
	render()
	return f
end

return M
