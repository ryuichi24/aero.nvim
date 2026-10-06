-- nvim --headless -u NONE -l tests/companion_managed.lua (build companion first)
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
assert(vim.uv.fs_mkdir(dir, 448))
local listener = vim.uv.new_tcp()
assert(listener:bind("127.0.0.1", 0))
local port = listener:getsockname().port
listener:close()
local origin = "http://127.0.0.1:" .. port
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	companion = { origin = origin, port = port, devices_file = dir .. "/devices.json" },
})
vim.cmd("runtime plugin/aero.lua")
local companion = require("aero.companion")
local function wait(fn)
	assert(vim.wait(10000, fn, 10), "managed companion timed out")
end
local function ready()
	wait(function()
		return companion.status().ready
	end)
end
local function request(path, method, body, cookie)
	local cmd = { "curl", "--silent", "--show-error", "--max-time", "5", "--include", "-X", method or "GET" }
	if body then
		vim.list_extend(
			cmd,
			{ "-H", "Origin: " .. origin, "-H", "Content-Type: application/json", "--data", vim.json.encode(body) }
		)
	end
	if cookie then
		vim.list_extend(cmd, { "-H", "Cookie: " .. cookie })
	end
	table.insert(cmd, origin .. path)
	local result
	vim.system(cmd, { text = true }, function(value)
		result = value
	end)
	wait(function()
		return result ~= nil
	end)
	assert(result.code == 0, "HTTP request failed")
	return result.stdout
end
assert(vim.tbl_contains(vim.fn.getcompletion("Aero companion ", "cmdline"), "pair"))
vim.cmd("Aero companion start")
ready()
local status = companion.status()
assert(status.pid and status.info.code:match("^%d%d%d%d%d%d$"), "start did not launch a six-digit pairing bridge")
local window = require("aero.companion_ui").window()
assert(window and vim.api.nvim_win_is_valid(window), "pairing popup missing")
local popup = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(window), 0, -1, false), "\n")
assert(popup:find(origin, 1, true) and popup:find(status.info.code, 1, true), "URL/code missing from popup")
local pid = status.pid
vim.cmd("Aero companion start")
assert(companion.status().pid == pid, "repeated start spawned another process")
local response = request("/api/pair", "POST", { code = status.info.code, name = "Remembered phone" })
assert(response:match("HTTP/%S+ 200"), "pairing failed")
local cookie = assert(response:match("[Ss]et%-[Cc]ookie: ([^;\r\n]+)"))
assert(response:find("Max%-Age=31536000"), "cookie was not persistent")
wait(function()
	return #(companion.status().info.devices or {}) == 1
end)
local store = assert(vim.json.decode(table.concat(vim.fn.readfile(dir .. "/devices.json"), "\n")))
assert(store.version == 1 and #store.devices == 1 and store.devices[1].name == "Remembered phone")
vim.cmd("Aero companion stop")
wait(function()
	return companion.status().pid == nil
end)
vim.cmd("Aero companion start")
ready()
assert(#companion.status().info.devices == 1, "restart forgot the device")
assert(request("/api/snapshot", "GET", nil, cookie):match("HTTP/%S+ 200"), "remembered cookie failed after restart")
local select = vim.ui.select
vim.ui.select = function(items, _, callback)
	assert(#items == 1)
	callback(items[1])
end
vim.cmd("Aero companion revoke")
wait(function()
	return #companion.status().info.devices == 0
end)
vim.ui.select = select
assert(request("/api/snapshot", "GET", nil, cookie):match("HTTP/%S+ 401"), "revoked cookie was accepted")
vim.cmd("Aero companion stop")
wait(function()
	return companion.status().pid == nil
end)
vim.cmd("Aero companion start")
ready()
assert(#companion.status().info.devices == 0, "revocation did not survive restart")
assert(request("/api/snapshot", "GET", nil, cookie):match("HTTP/%S+ 401"))
vim.cmd("Aero companion pair")
wait(function()
	return companion.status().info.event == "pairing"
end)
assert(companion.status().info.code:match("^%d%d%d%d%d%d$"))
vim.cmd("Aero companion stop")
wait(function()
	return companion.status().pid == nil
end)
vim.fn.delete(dir, "rf")
print("managed companion: start, popup, remembered devices, restart, and revocation passed")
vim.cmd("qa!")
