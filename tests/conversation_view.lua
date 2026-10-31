vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
root = assert(vim.uv.fs_realpath(root))
local original = api.nvim_get_current_tabpage()
local dashboards = { [original] = true }
local position = "left"
local opened = 0
local panel_enabled = true
local shown, target, presentation
package.loaded["aero.config"] = { options = { dashboard = { position = position } } }
package.loaded["aero.dashboard"] = {
	is_open = function()
		return dashboards[api.nvim_get_current_tabpage()] == true
	end,
	open = function()
		opened = opened + 1
		dashboards[api.nvim_get_current_tabpage()] = true
	end,
}
package.loaded["aero.navigation"] = {
	code_window = function()
		return api.nvim_get_current_win()
	end,
}
package.loaded["aero.session"] = {
	show = function(session, win)
		shown, target, presentation = session, win, "session"
		vim.cmd.vsplit()
		return win
	end,
}
package.loaded["aero.panel"] = {
	enabled = function()
		return panel_enabled
	end,
	show = function(session)
		shown, target, presentation = session, api.nvim_get_current_win(), "panel"
		return target
	end,
}
local views = require("aero.conversation_view")
local general, knowledge = views.new(), views.new()
local session = { key = "test" }
local win = general.show(session, { directory = root .. "/general chat" })
local general_tab = api.nvim_get_current_tabpage()

assert(general_tab ~= original)
assert(opened == 1 and dashboards[general_tab], "dashboard did not follow into new tab")
assert(win == target and api.nvim_get_current_win() == win, "returned window was not focused")
assert(shown == session and presentation == "session")
assert(vim.fn.getcwd() == root .. "/general chat", "directory with spaces was not selected")

knowledge.show(session, { directory = root .. "/space-one", panel = true })
local knowledge_tab = api.nvim_get_current_tabpage()

assert(knowledge_tab ~= general_tab and knowledge_tab ~= original, "view tabs are not isolated")
assert(presentation == "panel")

knowledge.show(session, { directory = root .. "/space-two", panel = true })

assert(api.nvim_get_current_tabpage() == knowledge_tab, "view did not reuse its tab")
assert(vim.fn.getcwd() == root .. "/space-two", "reused tab kept previous scope directory")

panel_enabled = false
knowledge.show(session, { directory = root .. "/space-two", panel = true })

assert(presentation == "session", "disabled panel did not fall back to session view")

general.show(session, { directory = root .. "/general chat" })

assert(api.nvim_get_current_tabpage() == general_tab)
assert(vim.fn.getcwd() == root .. "/general chat", "other view changed this tab's directory")

vim.cmd("tabclose!")
general.show(session, { directory = root .. "/general chat" })

assert(api.nvim_get_current_tabpage() ~= general_tab, "closed tab was not recreated")

-- A hidden dashboard stays hidden, and current-window dashboards are not copied.
api.nvim_set_current_tabpage(original)
dashboards[original] = nil
local before = opened
views.new().show(session, { directory = root .. "/hidden" })

assert(opened == before)

api.nvim_set_current_tabpage(original)
dashboards[original] = true
package.loaded["aero.config"].options.dashboard.position = "current"
views.new().show(session, { directory = root .. "/current" })

assert(opened == before)

api.nvim_set_current_tabpage(original)
vim.fn.delete(root, "rf")
print("Conversation view tests passed")
