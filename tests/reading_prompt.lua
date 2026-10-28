vim.opt.rtp:prepend(vim.fn.getcwd())
local prompt = require("aero.acp.prompt")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)
local chat = { prompt_buf = buf }

local function lines(value, row)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, value)
	vim.api.nvim_win_set_cursor(0, { row or 1, 0 })
end

lines({ "Trace token validation.", "/reading Authentication flow", "Include error branches." }, 2)

assert(prompt.command(chat))

local draft = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

assert(draft[1] == "Trace token validation." and draft[3] == "Include error branches.")
assert(draft[2]:find('titled "Authentication flow"', 1, true))
assert(draft[2]:find("aero_reading_list_publish", 1, true))

lines({ "/reading" })
vim.ui.input = function(_, callback)
	callback("Error handling")
end

assert(prompt.command(chat))
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]:find('"Error handling"', 1, true))

lines({ "/reading" })
vim.ui.input = function(_, callback)
	callback(nil)
end

assert(prompt.command(chat))
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "/reading")

lines({ "/reading Submit flow" })
prompt.send(chat, true)

assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]:find('"Submit flow"', 1, true))

require("aero.config").options.reading.prompt = "Prepare {title}.\nPublish {title} with aero_reading_list_publish."
lines({ "Context", '/reading 100% "coverage"', "Keep this" }, 2)

assert(prompt.command(chat))

local custom = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local quoted = vim.json.encode('100% "coverage"')

assert(custom[1] == "Context" and custom[4] == "Keep this")
assert(custom[2] == "Prepare " .. quoted .. ".")
assert(custom[3] == "Publish " .. quoted .. " with aero_reading_list_publish.")

local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.fn.writefile({ "return true" }, root .. "/source.lua")
local reading = require("aero.reading")
local result = assert(reading.publish({ worktree = root, session_key = "old-session" }, {
	title = "Existing walkthrough",
	items = { { id = "entry", path = "source.lua", lnum = 1, label = "Entry" } },
}))
chat.s = { worktree = root, key = "current-session" }
vim.ui.select = function(items, _, callback)
	assert(#items == 1 and items[1].id == result.id)

	callback(items[1])
end
lines({ "My instructions", "/reading-update", "Keep this too" }, 2)

assert(prompt.command(chat))

local updated = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
local request = table.concat(updated, "\n")

assert(updated[1] == "My instructions" and updated[#updated] == "Keep this too")
assert(request:find(result.id, 1, true))
assert(not request:find('"id":"entry"', 1, true))
assert(request:find("aero_reading_list_publish", 1, true))
assert(reading.load(root, result.id).session_key == chat.s.key)

local reference = updated[#updated - 1]
local source = reference:sub(2)

if source:sub(1, 1) == '"' then
	source = vim.json.decode(source)
end

assert(reference:sub(1, 1) == "@" and source:sub(1, 1) == "/")
assert(vim.fn.filereadable(source) == 1)

local referenced = vim.json.decode(table.concat(vim.fn.readfile(source), "\n"))

assert(referenced.id == result.id and referenced.items[1].id == "entry")

vim.ui.select = function(_, _, callback)
	callback(nil)
end
lines({ "/reading-update" })
prompt.send(chat, true)

assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "/reading-update")

vim.ui.select = function(items, _, callback)
	lines({ "Edited while choosing" })
	callback(items[1])
end
lines({ "/reading-update" })

assert(prompt.command(chat))
assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "Edited while choosing")

vim.fn.delete(root, "rf")
print("reading prompt: ok")
