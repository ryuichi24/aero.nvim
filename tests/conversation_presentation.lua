vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local original = api.nvim_get_current_win()
local session = { key = "conversation" }
local panel_enabled = true
local shown, reused, destination, entered
local fail = false
local panel_calls = 0
package.loaded["aero.navigation"] = {
	code_window = function()
		return original
	end,
}
package.loaded["aero.session"] = {
	show = function(value, win, reuse)
		shown, destination, reused = value, win, reuse
		return not fail and win or nil
	end,
	enter = function(value)
		entered = value
	end,
}
package.loaded["aero.panel"] = {
	enabled = function()
		return panel_enabled
	end,
	show = function(value)
		panel_calls = panel_calls + 1
		shown = value
		return not fail and original or nil
	end,
}
local presentation = require("aero.conversation_presentation")
local win = presentation.show(session, { reuse = true })

assert(win == original and destination == original and reused == true and shown == session)

presentation.focus(session, win)

assert(not entered, "browsing entered the session")

presentation.focus(session, win, true)

assert(entered == session)

entered = nil

for _, split in ipairs({ "vsplit", "split", "tab" }) do
	win = presentation.show(session, { split = split, reuse = false })

	assert(win ~= original and destination == win and reused == false)

	presentation.focus(session, win)

	assert(api.nvim_get_current_win() == win)

	if split == "tab" then
		assert(api.nvim_get_current_tabpage() ~= api.nvim_win_get_tabpage(original))

		vim.cmd("tabclose!")
	else
		vim.cmd("close!")
	end
end

assert(presentation.show(session, { panel = true }) == original)
assert(panel_calls == 1)

panel_enabled = false

assert(presentation.show(session, { panel = true }) == original)
assert(panel_calls == 1 and reused == nil, "panel fallback changed reuse policy")

fail = true
win = presentation.show(session, {})

assert(not win)
assert(not presentation.focus(session, win, true))
assert(not entered, "failed presentation entered the session")

panel_enabled = true
win = presentation.show(session, { panel = true })

assert(not win)
assert(not presentation.focus(session, win, true))
assert(not entered)

print("Conversation presentation tests passed")
