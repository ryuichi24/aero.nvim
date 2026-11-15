-- Run from the repository root: python3 tests/run.py --unit session_picker
vim.opt.rtp:prepend(vim.fn.getcwd())
local session = require("aero.session")
local repositories = require("aero.repositories")
local scenes = require("aero.scenes")
local picker = require("aero.session.picker")
local selected = { worktree = "/project", name = "Investigate", agent = "fixture" }
local listed, activated, opened, callback, items, options, all_scope
local loader = function() end
session.list = function(path)
	listed = path
	return { selected }
end
session.icon = function()
	return "busy"
end
session.activity = function()
	return "thinking"
end
scenes.activate = function(value)
	activated = value
end
repositories.list = function(load, all)
	assert(load == loader)

	all_scope = all
	return { { ws = { name = "Project" }, list = { { path = "/project", head = "123456789" } } } }
end
vim.ui.select = function(choices, opts, done)
	items, options, callback = choices, opts, done
end
local function open(value)
	assert(activated == value, "scene must activate before opening the selected session")

	opened = value
end

vim.t.aero_worktree = "/current"
picker.open("current", { open_session = open })

assert(listed == "/current")
assert(#items == 1 and items[1].session == selected)
assert(options.format_item(items[1]) == "busy Investigate [fixture]  thinking")

callback(nil)

assert(not opened and not activated, "cancelling selection must not navigate")

callback(items[1])

assert(opened == selected)

picker.open("all", { load_worktrees = loader, open_session = open })

assert(all_scope == true)
assert(listed == "/project")
assert(options.format_item(items[1]) == "busy Project / (detached 1234567) / Investigate  thinking")

picker.open(nil, { load_worktrees = loader, open_session = open })

assert(all_scope == false)

session.list = function()
	return {}
end
local notified
vim.notify = function(message)
	notified = message
end
vim.ui.select = function()
	error("an empty picker must not open")
end
picker.open("current")

assert(notified == "Aero: no sessions")

print("Session picker tests passed.")
