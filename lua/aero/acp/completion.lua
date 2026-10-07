-- Automatic suggestions reuse the prompt's omnifunc, including provider commands.
local M = {}
local api = vim.api

local function truncate(text, width)
	width = math.max(0, width)
	if vim.fn.strdisplaywidth(text) <= width then return text end
	if width == 0 then return "" end
	while vim.fn.strdisplaywidth(text) > width - 1 do
		text = vim.fn.strcharpart(text, 0, vim.fn.strchars(text) - 1)
	end
	return text .. "…"
end

function M.fit(items, width)
	local longest, kind_width = 0, 0
	local fitted = vim.deepcopy(items)
	for _, item in ipairs(fitted) do
		item.abbr = truncate(item.abbr or item.word, width - 4)
		item.kind = truncate(item.kind or "", math.max(0, width - vim.fn.strdisplaywidth(item.abbr) - 4))
		longest = math.max(longest, vim.fn.strdisplaywidth(item.abbr))
		kind_width = math.max(kind_width, vim.fn.strdisplaywidth(item.kind))
	end
	-- Popup columns use independent maxima across ALL rows, not each row's total.
	for _, item in ipairs(fitted) do
		item.kind = truncate(item.kind, width - longest - 4)
	end
	kind_width = math.min(kind_width, math.max(0, width - longest - 4))
	for _, item in ipairs(fitted) do
		item.menu = truncate(item.menu or "", width - longest - kind_width - 4)
	end
	return fitted
end

function M.candidates()
	local before = api.nvim_get_current_line():sub(1, api.nvim_win_get_cursor(0)[2])
	-- Only suggest commands at the beginning of the prompt line, not prose paths.
	if not before:match("^%s*/[%w_-]*$")
		and not before:match("^%s*/model%s+[^%s]*$")
		and not before:match("^%s*/mode%s+[^%s]*$") then
		return
	end
	local acp = require("aero.acp")
	local start = acp.omnifunc(1, "")
	if start < 0 then return end
	return start + 1, acp.omnifunc(0, before:sub(start + 1))
end

function M.setup(buf, root)
	vim.bo[buf].completeopt = "menu,menuone,noinsert,noselect"
	local saved
	local paths = require("aero.acp.paths")
	local path_menu = require("aero.acp.path_menu")
	local guard = require("aero.acp.completion_guard")
	local bind
	guard.apply(buf)
	local path_items, loading, last_signature
	local has_maxwidth = vim.fn.exists("+pummaxwidth") == 1
	local function constrain(start)
		if not saved then
			saved = { width = vim.o.pumwidth, maxwidth = has_maxwidth and vim.o.pummaxwidth }
		end
		local info = vim.fn.getwininfo(api.nvim_get_current_win())[1]
		local prefix = api.nvim_get_current_line():sub(1, (start or 1) - 1)
		local width = math.max(1, api.nvim_win_get_width(0) - info.textoff - vim.fn.strdisplaywidth(prefix) - 2)
		vim.o.pumwidth = math.min(saved.width, width)
		if has_maxwidth then
			vim.o.pummaxwidth = saved.maxwidth > 0 and math.min(saved.maxwidth, width) or width
		end
		return width
	end
	local function restore()
		path_menu.close()
		if saved then
			vim.o.pumwidth = saved.width
			if has_maxwidth then vim.o.pummaxwidth = saved.maxwidth end
			saved = nil
		end
	end
	api.nvim_create_autocmd("InsertEnter", { buffer = buf, callback = function()
		guard.apply(buf)
		bind()
		last_signature = nil
		if not loading then path_items = nil end
		constrain()
	end })
	-- FileType/LspAttach handlers may install completion mappings after compose.
	api.nvim_create_autocmd({ "FileType", "LspAttach" }, { buffer = buf, callback = function()
		vim.schedule(function()
			if api.nvim_buf_is_valid(buf) then
				guard.apply(buf)
				bind()
			end
		end)
	end })
	api.nvim_create_autocmd({ "InsertLeave", "BufLeave", "BufWipeout" }, { buffer = buf, callback = restore })
	local refresh
	refresh = function(force)
		if not api.nvim_buf_is_valid(buf) or api.nvim_get_current_buf() ~= buf
			or vim.fn.mode():sub(1, 1) ~= "i" then return end
		local visible = vim.fn.pumvisible() == 1
		local cursor = api.nvim_win_get_cursor(0)
		local before = api.nvim_get_current_line():sub(1, cursor[2])
		local signature = cursor[1] .. ":" .. before
		if not force and signature == last_signature then return end
		last_signature = signature
		local start, query = paths.token(before)
		local items
		if start and root then
			if visible then vim.fn.complete(cursor[2] + 1, {}) end
			if not path_items then
				if not loading then
					loading = true
					paths.items(root, function(found)
						loading, path_items = false, found
						refresh(true)
					end)
				end
				return
			end
			items = paths.candidates(path_items, query)
			path_menu.show(buf, start, items)
			return
		else
			path_menu.close()
			-- Native slash-command navigation inserts the highlighted word.
			if visible and vim.fn.complete_info({ "selected" }).selected >= 0 then return end
			if visible then return end
			start, items = M.candidates()
		end
		if start and items then
			vim.fn.complete(start, M.fit(items, constrain(start)))
		end
	end
	api.nvim_create_autocmd({ "TextChangedI", "TextChangedP", "CursorMovedI" }, {
		buffer = buf, callback = function() refresh(false) end,
	})
	api.nvim_create_autocmd("CompleteChanged", { buffer = buf, callback = function()
		if not path_menu.visible(buf) then return end
		-- CompleteChanged has textlock; dismiss unexpected native menus afterwards.
		vim.schedule(function()
			if api.nvim_get_current_buf() == buf and path_menu.visible(buf)
				and vim.fn.mode():sub(1, 1) == "i" and vim.fn.pumvisible() == 1 then
				vim.fn.complete(api.nvim_win_get_cursor(0)[2] + 1, {})
			end
		end)
	end })
	bind = function()
		for key, completion in pairs({ ["<Tab>"] = "<C-n>", ["<S-Tab>"] = "<C-p>",
			["<C-n>"] = "<C-n>", ["<C-p>"] = "<C-p>", ["<Down>"] = "<C-n>", ["<Up>"] = "<C-p>" }) do
			vim.keymap.set("i", key, function()
				if path_menu.visible(buf) then
					path_menu.move(buf, completion == "<C-n>" and 1 or -1)
					return
				end
				local keys = vim.fn.pumvisible() == 1 and completion or key
				api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "in", false)
			end, { buffer = buf, desc = "Aero: navigate prompt suggestions" })
		end
		vim.keymap.set("i", "<C-e>", function()
			if path_menu.visible(buf) then
				path_menu.close()
				return
			end
			api.nvim_feedkeys(api.nvim_replace_termcodes("<C-e>", true, false, true), "in", false)
		end, { buffer = buf, desc = "Aero: dismiss prompt suggestions" })
	end
	bind()
end

return M
