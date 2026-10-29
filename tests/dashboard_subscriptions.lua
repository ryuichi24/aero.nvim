vim.opt.rtp:prepend(vim.fn.getcwd())
local changes = require("aero.listeners").new("fixture")
local frames = require("aero.listeners").new("fixture frames")
package.loaded["aero.session"] = { on_change = changes.on }
package.loaded["aero.spinner"] = { on_frame = frames.on }
local events = require("aero.events")
local subscriptions = require("aero.dashboard.subscriptions")
local renders, loads, animations = 0, 0, 0
local callbacks = {
	visible = function()
		return true
	end,
	render = function()
		renders = renders + 1
	end,
	load = function()
		loads = loads + 1
	end,
	animate = function()
		animations = animations + 1
		return true
	end,
}
local dispose = subscriptions.attach(callbacks)
changes.emit()
events.emit("reference_changed")
events.emit("workspace_added")
vim.api.nvim_exec_autocmds("User", { pattern = "AeroTaskChanged" })

assert(renders == 0)
assert(vim.wait(1000, function()
	return renders == 1
end))
assert(loads == 1, "reload intent was dropped while coalescing")
assert(frames.emit() and animations == 1)

events.emit("reading_changed")
dispose()
changes.emit()
events.emit("workspace_added")

assert(not frames.emit())

local dispose_next = subscriptions.attach(callbacks)
events.emit("reports_changed")

assert(vim.wait(1000, function()
	return renders == 2
end))
assert(loads == 1 and animations == 1, "disposed subscriptions still ran")

dispose_next()
print("Dashboard subscriptions passed (coalescing, reload intent, disposal, replacement).")
vim.cmd("qa!")
