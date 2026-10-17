-- Oil-style navigation with explicit, save-to-stage copy/cut operations.
local api = vim.api
local M = {}
local active

local function warn(err)
	vim.notify("Aero: " .. tostring(err), vim.log.levels.WARN)
end

function M.open(worktree)
	if active then
		if api.nvim_win_is_valid(active.win) then
			api.nvim_set_current_win(active.win)
		end
		return active
	end
	local home = vim.fn.expand(require("aero.config").options.reference_finder.home)
	if vim.fn.isdirectory(home) ~= 1 then
		return warn("reference_finder.home is not a directory: " .. home)
	end
	vim.cmd.stopinsert()
	local f =
		{ worktree = worktree, directory = vim.fs.normalize(vim.fn.fnamemodify(home, ":p")), pending = {}, staged = {} }
	local worktree_label = vim.fs.basename(worktree):gsub("[%c]", " ")
	local worktree_path = vim.fn.fnamemodify(worktree, ":~"):gsub("[%c]", " ")
	local finder_title = " Reference finder · target: " .. worktree_label .. " "
	local previous = api.nvim_get_current_win()
	f.buf = api.nvim_create_buf(false, true)
	f.stack = api.nvim_create_buf(false, true)
	vim.bo[f.buf].buftype = "acwrite"
	vim.bo[f.buf].swapfile = false
	vim.bo[f.buf].bufhidden = "hide"
	vim.bo[f.buf].filetype = "aero_reference"
	api.nvim_buf_set_name(f.buf, "aero-reference://" .. f.buf)
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
		footer = " Worktree: " .. worktree_path .. " ",
	})
	f.stack_win = api.nvim_open_win(f.stack, false, {
		relative = "editor",
		row = height + 3,
		col = 2,
		width = width,
		height = stack_height,
		style = "minimal",
		border = "rounded",
		title = " Staged references → " .. worktree_label .. " ",
		focusable = false,
		footer = " :w to stage · q to finish · target: " .. worktree_path .. " ",
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
			table.insert(lines, "  " .. item.action .. "  " .. item.path)
		end
		if #lines == 0 then
			lines = { "  No staged items. y: copy · d: cut · u: unmark · Enter/l: enter · -/h: parent" }
		end
		set_lines(f.stack, lines)
		api.nvim_win_set_cursor(f.stack_win, { #lines, 0 })
	end
	local function render()
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
			table.insert(f.entries, { name = name, path = vim.fs.joinpath(f.directory, name), kind = kind })
		end
		table.sort(f.entries, function(a, b)
			if (a.kind == "directory") ~= (b.kind == "directory") then
				return a.kind == "directory"
			end
			return a.name < b.name
		end)
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
		vim.bo[f.buf].modified = next(f.pending) ~= nil
		api.nvim_win_set_config(f.win, {
			title = finder_title .. "· browsing: " .. f.directory:gsub("[%c]", " ") .. " ",
		})
	end
	local function save()
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
		local remaining = vim.tbl_filter(function(item)
			return not item.done
		end, f.staged)
		local ok, result, err = pcall(require("aero.reference").transfer, worktree, remaining)
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
					footer = " Worktree: " .. worktree_path .. " ",
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
		stack()
		render()
	end
	for key, action in pairs({ y = "copy", d = "cut", u = false }) do
		vim.keymap.set({ "n", "x" }, key, function()
			mark(action or nil)
		end, { buffer = f.buf, nowait = true })
	end
	for _, key in ipairs({ "<CR>", "l" }) do
		vim.keymap.set("n", key, function()
			local item = f.entries[api.nvim_win_get_cursor(f.win)[1]]
			if item and vim.fn.isdirectory(item.path) == 1 then
				f.directory = item.path
				render()
			end
		end, { buffer = f.buf })
	end
	for _, key in ipairs({ "-", "h" }) do
		vim.keymap.set("n", key, function()
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
