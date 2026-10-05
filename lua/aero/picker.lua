-- Shared searchable popup with normal-mode navigation and optional group headings.
local M = {}
local api = vim.api
local popup
local namespace = api.nvim_create_namespace("aero.picker")

local function clean(text)
	return (text:gsub("[%c]", " "))
end

function M.close()
	local p = popup
	if not p then
		return
	end
	popup = nil
	if p.timer then
		p.timer:stop()
		p.timer:close()
	end
	vim.cmd.stopinsert()
	for _, win in ipairs({ p.search_win, p.list_win }) do
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
	end
end

local function render()
	local p = popup
	if not p then
		return
	end
	local previous = p.items[p.index]
	local query = table.concat(api.nvim_buf_get_lines(p.search, 0, -1, false), " "):lower()
	local items = {}
	for _, s in ipairs(p.opts.items()) do
		local text = p.opts.search and p.opts.search(s) or p.opts.label(s)
		local matches = true
		for word in query:gmatch("%S+") do
			if not text:lower():find(word, 1, true) then
				matches = false
				break
			end
		end
		if matches then
			table.insert(items, s)
		end
	end
	if p.opts.sort then
		table.sort(items, p.opts.sort)
	end
	p.items = items
	p.index = math.max(1, math.min(p.index, #items))
	for i, s in ipairs(items) do
		if previous and s.key == previous.key then
			p.index = i
		end
	end
	local lines = {}
	local headings = {}
	local group
	p.rows = {}
	for i, s in ipairs(items) do
		local heading = p.opts.group and p.opts.group(s)
		if heading and heading ~= group then
			if group then
				table.insert(lines, "")
			end
			group = heading
			table.insert(lines, clean(heading))
			table.insert(headings, #lines - 1)
		end
		table.insert(lines, clean(p.opts.label(s)))
		p.rows[i] = #lines
	end
	vim.bo[p.list].modifiable = true
	api.nvim_buf_set_lines(p.list, 0, -1, false, #lines > 0 and lines or { "No matching " .. p.opts.title })
	vim.bo[p.list].modifiable = false
	api.nvim_buf_clear_namespace(p.list, namespace, 0, -1)
	for _, row in ipairs(headings) do
		api.nvim_buf_set_extmark(p.list, namespace, row, 0, {
			end_row = row + 1,
			hl_group = "Title",
		})
	end
	api.nvim_win_set_cursor(p.list_win, { p.rows[p.index] or 1, 0 })
end

function M.open(opts)
	if popup and popup.opts.title == opts.title then
		api.nvim_set_current_win(popup.search_win)
		return
	end
	M.close()
	if #opts.items() == 0 then
		vim.notify("Aero: no " .. opts.title, vim.log.levels.INFO)
		return
	end
	local width = math.max(1, math.min(100, vim.o.columns - 4))
	local height = math.max(1, math.min(12, vim.o.lines - 8))
	local row = math.max(0, math.floor((vim.o.lines - height - 6) / 2))
	local col = math.max(0, math.floor((vim.o.columns - width - 2) / 2))
	local p = { items = {}, index = 1, opts = opts }
	p.search = api.nvim_create_buf(false, true)
	p.list = api.nvim_create_buf(false, true)
	for _, buf in ipairs({ p.search, p.list }) do
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = opts.filetype or "aero_picker"
	end
	p.list_win = api.nvim_open_win(p.list, false, {
		relative = "editor",
		row = row + 3,
		col = col,
		width = width,
		height = height,
		style = "minimal",
		border = "rounded",
		focusable = false,
		footer = " j/k: select · i: filter · Enter: open · q: close ",
	})
	vim.wo[p.list_win].cursorline = true
	vim.wo[p.list_win].wrap = false
	p.search_win = api.nvim_open_win(p.search, true, {
		relative = "editor",
		row = row,
		col = col,
		width = width,
		height = 1,
		style = "minimal",
		border = "rounded",
		title = " Aero " .. opts.title .. " · search ",
	})
	popup = p
	local function move(delta)
		if popup == p and #p.items > 0 then
			p.index = (p.index - 1 + delta) % #p.items + 1
			api.nvim_win_set_cursor(p.list_win, { p.rows[p.index], 0 })
		end
	end
	local function select()
		local s = p.items[p.index]
		if not s then
			return
		end
		M.close()
		opts.select(s)
	end
	for _, mode in ipairs({ "n", "i" }) do
		for _, key in ipairs({ "<Down>", "<C-n>" }) do
			vim.keymap.set(mode, key, function()
				move(1)
			end, { buffer = p.search })
		end
		for _, key in ipairs({ "<Up>", "<C-p>" }) do
			vim.keymap.set(mode, key, function()
				move(-1)
			end, { buffer = p.search })
		end
		vim.keymap.set(mode, "<CR>", select, { buffer = p.search })
	end
	vim.keymap.set("n", "q", M.close, { buffer = p.search })
	vim.keymap.set("n", "j", function()
		move(1)
	end, { buffer = p.search })
	vim.keymap.set("n", "k", function()
		move(-1)
	end, { buffer = p.search })
	-- Leave filtering mode without dismissing the popup.
	vim.keymap.set("i", "<Esc>", "<Esc>", { buffer = p.search })
	api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { buffer = p.search, callback = render })
	api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(p.search_win),
		once = true,
		callback = function()
			if popup == p then
				M.close()
			end
		end,
	})
	if opts.live then
		p.timer = vim.uv.new_timer()
		p.timer:start(
			200,
			200,
			vim.schedule_wrap(function()
				if popup == p then
					render()
				end
			end)
		)
	end
	render()
	vim.cmd.stopinsert()
end

return M
