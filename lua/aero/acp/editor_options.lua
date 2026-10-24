-- Window-local ACP options must be applied in the window displaying the buffer.
local api = vim.api
local M = {}
M.transcript = { wrap = true, linebreak = true, conceallevel = 2, foldenable = true, foldmethod = "manual" }

function M.line_numbers(kind)
	local config = require("aero.config").options.acp.line_numbers[kind]
	return { number = config.show, relativenumber = config.show and config.relative }
end

function M.apply(win, extra)
	for name, value in
		pairs(vim.tbl_extend("force", { foldenable = false, number = false, relativenumber = false }, extra or {}))
	do
		api.nvim_set_option_value(name, value, { win = win, scope = "local" })
	end
end

function M.filetype(buf, filetype)
	local win = vim.fn.bufwinid(buf)
	if win ~= -1 then
		api.nvim_win_call(win, function()
			vim.bo[buf].filetype = filetype
		end)
	else
		vim.bo[buf].filetype = filetype
	end
end

return M
