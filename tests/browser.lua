vim.opt.rtp:prepend(vim.fn.getcwd())
local api, uv = vim.api, vim.uv
vim.env.SSH_CONNECTION, vim.env.SSH_TTY = nil, nil
require("aero.config").setup({ companion = { auto_start = false }, browser = { cmd = { "true" } } })
local reader = require("aero.reader")
reader.setup()
local browser = require("aero.browser")
local detected_cell
require("aero.browser.terminal").cell = function()
	return detected_cell
end
local drawn
local channel_send = api.nvim_chan_send
api.nvim_chan_send = function(channel, data)
	if data:find(vim.fn.nr2char(0x10eeee), 1, true) then
		drawn = data
	end

	return channel_send(channel, data)
end
local launches, stopped, notices, clients, incoming = {}, {}, {}, {}, {}
local controls = {}
local host_frames = false
local control_path = vim.fn.tempname() .. ".sock"
local control_server = assert(uv.new_pipe(false))

assert(control_server:bind(control_path))

control_server:listen(8, function()
	local client = assert(uv.new_pipe(false))
	control_server:accept(client)
	clients[#clients + 1] = client
	client:read_start(function(_, data)
		if data then
			controls[#controls + 1] = vim.json.decode(data)

			assert(controls[#controls].id == "aero")

			client:write(vim.json.encode({ id = "aero", ok = true, data = {} }) .. "\n")
		end
	end)
end)

vim.notify = function(message)
	notices[#notices + 1] = message
end
vim.system = function(command, _, callback)
	if command[2] == "capabilities" then
		return {
			wait = function()
				return {
					code = 0,
					stdout = vim.json.encode({
						capabilities = host_frames and { "embedding", "image-frames" } or { "embedding" },
					}),
				}
			end,
		}
	end

	if command[1] == "ps" then
		return {
			wait = function()
				return { code = 0, stdout = "ttys999\n" }
			end,
		}
	end

	assert(vim.deep_equal(command, { "true", "ls", "--all", "--json" }))

	local found = {}

	for index, launch in ipairs(launches) do
		found[#found + 1] = {
			key = "browser-" .. index,
			socket = control_path,
			parentTty = launch.env.PIXEL_EMBED,
			tabs = {
				{ id = index * 10, active = true, title = "App", url = "http://localhost:3000" },
				{ id = index * 10 + 1, active = false, title = "Docs", url = "https://example.com" },
			},
		}
	end

	callback({ code = 0, stdout = vim.json.encode({ browsers = found }) })
end
api.nvim_list_uis = function()
	return { { width = 80, height = 24 } }
end
vim.fn.jobstop = function(job)
	stopped[job] = true
	return 1
end
vim.fn.jobstart = function(command, options)
	launches[#launches + 1] = options
	local index = #launches
	options.command = command
	local client = assert(uv.new_pipe(false))
	clients[#clients + 1] = client
	options.client = client
	client:connect(options.env.PIXEL_EMBED, function(err)
		assert(not err, err)

		local pending = ""
		client:read_start(function(_, data)
			if not data then
				return
			end

			pending = pending .. data

			while pending:find("\n", 1, true) do
				local last = pending:find("\n", 1, true)
				incoming[#incoming + 1] = { browser = index, message = vim.json.decode(pending:sub(1, last - 1)) }
				pending = pending:sub(last + 1)
			end
		end)
		client:write('{"type":"jo')
		client:write('in","name":"fixture"}\n')
	end)
	return index
end

local function wait(predicate)
	assert(vim.wait(2000, predicate, 10), "browser fixture timed out")
end

local function received(kind, index)
	for _, entry in ipairs(incoming) do
		if entry.browser == index and entry.message.type == kind then
			return entry.message
		end
	end
end

vim.t.aero_worktree = vim.fn.getcwd()
local source = api.nvim_get_current_buf()
api.nvim_buf_set_lines(source, 0, -1, false, { "unsaved source" })
vim.wo.number = true
local win = reader.attach(api.nvim_get_current_win())
browser.command({ "open", "https://example.com/first" })
local first = api.nvim_get_current_buf()

assert(reader.active() == "browser")
assert(first ~= source)
assert(vim.bo[first].buftype == "terminal")
assert(not vim.wo.number)
assert(#launches == 1)
assert(launches[1].command[3] == "https://example.com/first")
assert(launches[1].cwd == vim.fn.getcwd())
assert(launches[1].env.PIXEL_TTY == "/dev/ttys999")

wait(function()
	return received("init", 1) ~= nil
end)
local init = received("init", 1)

assert(init.transport == "file")
assert(init.cols == api.nvim_win_get_width(win))
assert(init.width == init.cols * 10)

launches[1].client:write(vim.json.encode({ type = "placed", imageId = init.imageId, cols = 1000, rows = 2 }) .. "\n")
wait(function()
	return table.concat(api.nvim_buf_get_lines(first, 0, -1, false)):find(vim.fn.nr2char(0x10eeee), 1, true) ~= nil
end)
local encoded_row = assert(drawn:match("\027%[1;1H(.-)\027%[2;1H"))
local codepoints = vim.fn.str2list(encoded_row, true)

assert(#codepoints == 297 * 3, "Kitty supports exactly 297 coordinate diacritics")
assert(codepoints[15 * 3] == 0x0352, "Column 14 must encode Kitty's COMBINING FERMATA")
assert(codepoints[297 * 3] == 0x1d244)

for _, invalid in ipairs({ 0x065c, 0x06e3, 0x06ea, 0x06ed, 0x0711, 0x0742 }) do
	assert(not vim.tbl_contains(codepoints, invalid), "Unsupported Kitty coordinate diacritic")
end

detected_cell = { 7, 13 }
api.nvim_exec_autocmds("WinResized", {})
wait(function()
	for _, entry in ipairs(incoming) do
		if entry.browser == 1 and entry.message.type == "size" and entry.message.cell[1] == 7 then
			return entry.message.width == entry.message.cols * 7 and entry.message.height == entry.message.rows * 13
		end
	end
end)

assert(vim.deep_equal(browser.instance(vim.t.aero_worktree).cell, { 7, 13 }))

reader.select("source")

assert(api.nvim_get_current_buf() == source)
assert(vim.wo.number)
assert(vim.bo[source].modified)

reader.select("browser")

assert(api.nvim_get_current_buf() == first)
assert(#launches == 1)

browser.command({ "open", "https://example.com/second" })
wait(function()
	return #controls == 1
end)

assert(controls[1].cmd == "open-tab")
assert(controls[1].url == "https://example.com/second")

browser.command({ "next" })
wait(function()
	return #controls == 2
end)

assert(controls[2].tab == 11)

local attached
local sessions = require("aero.session")
local original_list = sessions.list
sessions.list = function(path)
	assert(path == vim.fn.getcwd())

	return { { name = "Agent", agent = "opencode" } }
end
local original_select = vim.ui.select
vim.ui.select = function(items, options, callback)
	callback(options.prompt == "Attach browser page" and items[2] or items[1])
end
local original_compose = package.loaded["aero.compose"]
package.loaded["aero.compose"] = {
	append = function(_, instruction)
		attached = instruction
		return true
	end,
}
browser.command({ "attach" })
wait(function()
	return attached ~= nil
end)

assert(attached:find("'--browser' 'browser-1' '--tab' '11'", 1, true))
assert(attached:find("https://example.com", 1, true))

sessions.list = original_list
vim.ui.select = original_select
package.loaded["aero.compose"] = original_compose

vim.cmd.tabnew()
vim.t.aero_worktree = "/tmp"
vim.env.SSH_CONNECTION = "192.0.2.1 12345 192.0.2.2 22"
reader.attach(api.nvim_get_current_win())
browser.command({ "open", "https://example.com/other" })
local second = api.nvim_get_current_buf()

assert(second ~= first)
assert(#launches == 2)
assert(launches[1].env.PIXEL_EMBED ~= launches[2].env.PIXEL_EMBED)

wait(function()
	return received("init", 2) ~= nil
end)

assert(received("init", 2).transport == "inline")
assert(vim.deep_equal(received("init", 2).cell, { 7, 13 }))

browser.command({ "prev" })
wait(function()
	return #controls == 3
end)

assert(controls[3].tab == 21)

browser.command({ "stop" })

assert(stopped[2])
assert(not stopped[1])
assert(not uv.fs_stat(launches[2].env.PIXEL_EMBED))

vim.cmd.tabprevious()
reader.select("browser")

assert(api.nvim_get_current_buf() == first)

browser.command({ "stop" })
host_frames = true
reader.select("browser")

assert(#launches == 3)
assert(api.nvim_get_current_buf() ~= first)

wait(function()
	return received("init", 3) ~= nil
end)

assert(received("init", 3).transport == "host")

browser.command({ "stop" })

assert(#notices == 0, table.concat(notices, "\n"))

for _, client in ipairs(clients) do
	if not client:is_closing() then
		client:close()
	end
end

control_server:close()
uv.fs_unlink(control_path)

local messages = {}
local input = require("aero.browser.input").new(function(message)
	messages[#messages + 1] = message
end, { 10, 20 })
input("a\r\027[1;")
input("5A\027[200~hello\n")
input("world\027[201~\027[<0;2;3M")

assert(messages[1].key == "a" and messages[1].text == "a")
assert(messages[2].key == "enter")
assert(messages[3].key == "up" and messages[3].mods.ctrl)
assert(messages[4].type == "paste" and messages[4].text == "hello\nworld")
assert(messages[5].type == "mouse" and messages[5].x == 15 and messages[5].y == 50)

print("browser: ok")
vim.cmd("qa!")
