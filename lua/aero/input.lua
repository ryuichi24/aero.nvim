-- Provider-specific enhancements without replacing the user's vim.ui.input.
local M = {}
local api = vim.api
M.adapters = {
	dressing = { filetype = "DressingInput" },
	snacks = { filetype = "snacks_input" },
}

local function select_default(buf, win, default, select_length)
	if not api.nvim_win_is_valid(win) or api.nvim_get_current_win() ~= win then
		return
	end

	if api.nvim_win_get_buf(win) ~= buf or api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= default then
		return
	end

	-- stopinsert takes effect after the current event. Selecting immediately
	-- while still in Insert mode makes that later transition move the cursor
	-- left once, dropping the final character from a partial selection.
	if vim.fn.mode():sub(1, 1) == "i" then
		vim.cmd.stopinsert()
		vim.defer_fn(function()
			select_default(buf, win, default, select_length)
		end, 1)
		return
	end

	-- Select mode replaces the text on typing, unlike Visual mode.
	api.nvim_win_set_cursor(win, { 1, 0 })

	if select_length and select_length > 0 and select_length < #default then
		-- Characterwise selection leaves a filename extension intact on replacement.
		vim.cmd("normal! v")

		-- Select through the dot, then move left once to leave the full stem
		-- selected. Native motion handles multibyte final characters correctly.
		api.nvim_win_set_cursor(win, { 1, select_length })
		vim.cmd("normal! h")
	else
		-- Shift+V selects the entire input line, including its final character.
		vim.cmd("normal! V")
	end

	-- Finish the selection synchronously so queued provider input cannot move
	-- the boundary before we enter Select mode.
	vim.cmd("normal! " .. api.nvim_replace_termcodes("<C-g>", true, false, true))

	-- Intercept printable replacement before native Select mode can copy the
	-- default to registers/clipboard. Restoring registers afterwards is too late
	-- for clipboard providers and TextYankPost listeners.
	local listener
	listener = vim.on_key(function(key)
		if api.nvim_get_current_buf() ~= buf or not vim.fn.mode():match("^[sS\019]") then
			return
		end

		if vim.fn.strchars(key) == 1 and vim.fn.char2nr(key) >= 32 and key:byte() ~= 128 then
			vim.on_key(nil, listener)
			local change = api.nvim_replace_termcodes('<C-g>"_c', true, false, true)
			api.nvim_feedkeys(change .. key, "in", false)
			return ""
		end
	end)
	local restore
	restore = api.nvim_create_autocmd({ "ModeChanged", "BufWipeout" }, {
		buffer = buf,
		callback = function(event)
			if event.event == "ModeChanged" and not vim.v.event.old_mode:match("^[sS\019]") then
				return
			end

			vim.on_key(nil, listener)
			api.nvim_del_autocmd(restore)
		end,
	})

	-- Input providers normally map confirmation only in Normal/Insert mode.
	vim.keymap.set("s", "<CR>", function()
		api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc><CR>", true, false, true), "m", false)
	end, { buffer = buf, desc = "Aero: confirm session name" })
end

--- Custom adapters are functions(opts, callback); built-ins enhance vim.ui.input.
function M.input(opts, callback)
	local config = require("aero.config").options.input

	if type(config.adapter) == "function" then
		return config.adapter(vim.tbl_extend("force", opts, { select_default = config.select_default }), callback)
	end

	local autocmd
	local saved_selection
	local active = true

	local function cleanup()
		if saved_selection then
			vim.o.selection = saved_selection
			saved_selection = nil
		end

		if autocmd then
			pcall(api.nvim_del_autocmd, autocmd)
			autocmd = nil
		end
	end

	if config.select_default and config.adapter ~= "vim_ui" and (opts.default or "") ~= "" then
		local patterns = {}

		for name, adapter in pairs(M.adapters) do
			if config.adapter == "auto" or config.adapter == name then
				table.insert(patterns, adapter.filetype)
			end
		end

		if #patterns > 0 then
			autocmd = api.nvim_create_autocmd("FileType", {
				pattern = patterns,
				once = true,
				callback = function(event)
					local win = api.nvim_get_current_win()
					vim.schedule(function()
						if active then
							if
								opts.select_length
								and opts.select_length > 0
								and opts.select_length < #(opts.default or "")
							then
								saved_selection = vim.o.selection
								vim.o.selection = "inclusive"
							end

							select_default(event.buf, win, opts.default, opts.select_length)
						end
					end)
				end,
			})
		end
	end

	local ok, result = pcall(vim.ui.input, opts, function(value)
		active = false
		cleanup()
		callback(value)
	end)

	if not ok then
		active = false
		cleanup()
		error(result)
	end

	return result
end

return M
