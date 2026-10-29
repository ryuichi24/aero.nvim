vim.opt.rtp:prepend(vim.fn.getcwd())
local registry = require("aero.listeners").new("fixture")
local calls, errors = {}, {}
vim.notify = function(message)
	table.insert(errors, message)
end
local dispose_later
local dispose_first = registry.on(function()
	table.insert(calls, "first")
	dispose_later()
	registry.on(function()
		table.insert(calls, "new")
	end)
	return true
end)
dispose_later = registry.on(function()
	error("disposed callback ran")
end)
registry.on(function()
	error("visible failure")
end)
registry.on(function()
	table.insert(calls, "last")
end)

assert(registry.emit())
assert(table.concat(calls, ",") == "first,last", "dispatch order or snapshot registration changed")
assert(vim.wait(1000, function()
	return #errors == 1
end))
assert(errors[1]:find("visible failure", 1, true))

dispose_first()
calls = {}

assert(not registry.emit())
assert(table.concat(calls, ",") == "last,new")

print("Listener tests passed (disposal, ordering, snapshot dispatch, error isolation).")
vim.cmd("qa!")
