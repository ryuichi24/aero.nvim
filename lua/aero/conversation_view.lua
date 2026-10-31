-- Each view owns a dedicated tab, independent of workspace tab management.
local M = {}

function M.new()
	local tab
	return {
		show = function(session, options)
			local dashboard = require("aero.dashboard")
			local had_dashboard = dashboard.is_open()

			if not tab or not vim.api.nvim_tabpage_is_valid(tab) then
				vim.cmd.tabnew()
				tab = vim.api.nvim_get_current_tabpage()
			end

			vim.api.nvim_set_current_tabpage(tab)
			vim.fn.mkdir(options.directory, "p")
			vim.cmd("tcd " .. vim.fn.fnameescape(options.directory))

			if
				had_dashboard
				and require("aero.config").options.dashboard.position ~= "current"
				and not dashboard.is_open()
			then
				dashboard.open()
			end

			local presentation = require("aero.conversation_presentation")
			return presentation.focus(session, presentation.show(session, { panel = options.panel }))
		end,
	}
end

return M
