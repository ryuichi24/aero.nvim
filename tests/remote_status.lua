-- Run: nvim --headless -u NONE -l tests/remote_status.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
require("aero").setup({ state_file = vim.fn.tempname(), animation = false })
local config = require("aero.config")
local remote = require("aero.remote_status")
local pending, started = {}, {}
require("aero.git").remote_status = function(root, cb)
	table.insert(started, root)
	pending[root] = cb
end
local changed = 0
local function callback()
	changed = changed + 1
end
for _, root in ipairs({ "one", "two", "three" }) do
	remote.request(root, callback)
end
assert(#started == 0, "fetch started before returning local results")
assert(vim.wait(1000, function()
	return #started == 2
end, 10))
remote.request("one", callback)
assert(#started == 2, "duplicate request escaped concurrency limit")
pending.one({ main = { behind = 1 } })
assert(changed == 1, "duplicate listener was notified twice")
assert(vim.wait(1000, function()
	return #started == 3
end, 10))
pending.two({})
pending.three({})
remote.request("one", callback)
vim.wait(20, function()
	return false
end)
assert(#started == 3, "fresh status was fetched again")
assert(remote.peek("one").statuses.main.behind == 1)
config.options.dashboard.remote_refresh_interval = 0
remote.request("one", callback)
assert(remote.peek("one").statuses.main.behind == 1, "stale status disappeared during refresh")
assert(vim.wait(1000, function()
	return #started == 4
end, 10))
pending.one(nil, "offline")
assert(remote.peek("one").fetch_err == "offline" and remote.peek("one").statuses.main)
config.options.dashboard.remote_refresh_interval = 60000
remote.request("one", callback)
vim.wait(20, function()
	return false
end)
assert(#started == 4, "failure retried without freshness backoff")
remote.invalidate()
remote.request("one", callback)
assert(vim.wait(1000, function()
	return #started == 5
end, 10))
pending.one({})
local store = require("aero.store")
store.data.workspaces = { { root = "/aero-perf-local", name = "Local" } }
require("aero.git").list = function(root)
	return { { path = root, branch = "main" } }
end
local dashboard = require("aero.dashboard")
dashboard.open()
local lines = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
assert(lines:find("main", 1, true) and #started == 5, "local rows did not precede fetch")
assert(vim.wait(1000, function()
	return #started == 6
end, 10))
pending["/aero-perf-local"]({ main = { ahead = 0, behind = 0 } })
dashboard.close()
dashboard.open()
vim.wait(20, function()
	return false
end)
assert(#started == 6, "reopening discarded fresh remote results")
print("remote status: ok")
vim.cmd("qa!")
