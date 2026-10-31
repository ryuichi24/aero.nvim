-- Display and focus conversations after the caller selects the navigation context.
local M = {}

function M.show(session, options)
	if options.panel and require("aero.panel").enabled() then
		return require("aero.panel").show(session)
	end

	local win = require("aero.navigation").code_window()

	if options.split then
		vim.api.nvim_set_current_win(win)
		vim.cmd(({ vsplit = "vsplit", split = "split", tab = "tab split" })[options.split])
		win = vim.api.nvim_get_current_win()
	end

	return require("aero.session").show(session, win, options.reuse)
end

function M.focus(session, win, enter)
	if win then
		vim.api.nvim_set_current_win(win)

		if enter then
			require("aero.session").enter(session)
		end
	end

	return win
end

return M
