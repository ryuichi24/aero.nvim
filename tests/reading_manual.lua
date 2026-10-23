vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_DATA_HOME = root .. "/data"
vim.t.aero_worktree = root
vim.fn.writefile({ "entry", "result" }, root .. "/source.lua")
local reading = require("aero.reading")
local chosen
vim.ui.select = function(items, _, callback)
	chosen = items[1]
	callback(chosen)
end
vim.ui.input = function(_, callback)
	callback("Manual tour")
end
reading.command("new")
local editor = vim.api.nvim_get_current_buf()
assert(vim.bo[editor].buftype == "acwrite")
assert(vim.json.decode(table.concat(vim.api.nvim_buf_get_lines(editor, 0, -1, false), "\n")).title == "Manual tour")
vim.cmd("edit " .. vim.fn.fnameescape(root .. "/source.lua"))
local source = vim.api.nvim_get_current_buf()
vim.ui.input = function(_, callback)
	callback("Start here")
end
reading.command("add")
local id = chosen.id
local list = reading.load(root, id)
assert(#list.items == 1 and list.items[1].label == "Start here" and list.items[1].lnum == 1)
assert(not list.session_key)
-- Reopen after source capture to obtain a fresh editor snapshot.
vim.api.nvim_buf_delete(editor, { force = true })
reading.command("edit")
editor = vim.api.nvim_get_current_buf()
local function write(document)
	vim.api.nvim_buf_set_lines(editor, 0, -1, false, vim.split(vim.json.encode(document), "\n"))
	vim.cmd.write()
end
write({
	title = "Renamed tour",
	items = {
		{ path = "source.lua", lnum = 2, label = "Result", note = "End here" },
		list.items[1],
	},
})
list = reading.load(root, id)
assert(list.title == "Renamed tour" and #list.items == 2)
assert(list.items[1].id and list.items[1].lnum == 2 and list.items[2].label == "Start here")
reading.command()
reading.command("toggle")
assert(reading.load(root, id).items[1].read)
vim.api.nvim_set_current_buf(editor)
list.items[1].note = "Updated explanation"
write({ title = list.title, items = list.items })
assert(reading.load(root, id).items[1].read, "manual editing must preserve read progress")
assert(vim.fn.getqflist()[1].text == "[x] Result")
write({ title = "Empty tour", items = {} })
assert(#reading.load(root, id).items == 0)
local notify = vim.notify
local error_message
vim.notify = function(message)
	error_message = message
end
write({ title = "Invalid", items = { { path = "missing.lua", lnum = 1, label = "Missing" } } })
assert(reading.load(root, id).title == "Empty tour" and vim.bo[editor].modified)
assert(error_message:find("existing file", 1, true))
vim.notify = notify
assert(not reading.publish({ worktree = root, session_key = "agent" }, {
	id = id,
	title = "Overwrite",
	items = { { id = "x", path = "source.lua", lnum = 1, label = "X" } },
}), "agents must not overwrite manually owned lists")
vim.api.nvim_set_current_buf(source)
vim.ui.input = function(_, callback)
	callback("Concurrent addition")
end
reading.command("add")
vim.api.nvim_set_current_buf(editor)
vim.notify = function(message)
	error_message = message
end
write({ title = "Stale", items = {} })
assert(error_message:find("changed since opening", 1, true))
assert(#reading.load(root, id).items == 1)
vim.notify = notify
vim.api.nvim_set_current_buf(source)
vim.ui.input = function(_, callback)
	callback(nil)
end
reading.command("add")
assert(#reading.load(root, id).items == 1)
vim.fn.delete(root, "rf")
print("manual reading: ok")
