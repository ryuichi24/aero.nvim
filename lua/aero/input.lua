-- Provider-specific enhancements without replacing the user's vim.ui.input.
local M = {}
local api = vim.api

M.adapters = {
	dressing = { filetype = "DressingInput" },
	snacks = { filetype = "snacks_input" },
}

local function select_default(buf, win, default)
	if not api.nvim_win_is_valid(win) or api.nvim_get_current_win() ~= win then
		return
	end
	if api.nvim_win_get_buf(win) ~= buf or api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= default then
		return
	end
	-- Select mode replaces the text on typing, unlike Visual mode.
	vim.cmd.stopinsert()
	api.nvim_win_set_cursor(win, { 1, 0 })
	-- Shift+V selects the entire input line, including its final character.
	vim.cmd("normal! V")
	api.nvim_feedkeys(api.nvim_replace_termcodes("<C-g>", true, false, true), "ni", false)
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
	local active = true
	local function cleanup()
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
							select_default(event.buf, win, opts.default)
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
