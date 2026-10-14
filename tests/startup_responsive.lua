-- Run: nvim --headless -u NONE -l tests/startup_responsive.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({ state_file = dir .. "/state.json", animation = false })
local ticks = 0
local timer = vim.uv.new_timer()
timer:start(10, 10, vim.schedule_wrap(function()
	ticks = ticks + 1
end))
local result = require("aero.install_progress").wait({ "sh", "-c", "sleep 0.2" }, 2000)
timer:stop()
timer:close()
assert(result.code == 0 and ticks >= 3, "subprocess wait blocked scheduled UI updates")

local frames = {}
require("aero.spinner").on_frame = function(fn)
	frames[#frames + 1] = fn
end
local store = require("aero.store")
store.data.workspaces = { { root = dir, name = "Workspace", expanded = true } }
require("aero.git").list = function()
	return { { path = dir, branch = "main" } }
end
require("aero.git").remote_status = function() end
local s = { key = dir .. "::test", worktree = dir, name = "test", agent = "test", job = 1, last_output = vim.uv.now() }
local session = require("aero.session")
session.list = function() return { s } end
session.all = function() return { s } end
local scans = 0
require("aero.tasks").list = function()
	scans = scans + 1
	return {}, {}
end
require("aero.tasks").list_removed = function() return {} end
require("aero.exports").list = function() return {} end
require("aero.reports").list = function() return {} end
require("aero.tasks.status").label = function() return "" end
require("aero.dashboard").open()
assert(scans > 0, "dashboard did not load task data")
local baseline = scans
for _ = 1, 5 do
	for _, frame in ipairs(frames) do frame() end
end
assert(scans == baseline, "spinner frames rescanned task metadata")
require("aero.dashboard").render()
assert(scans > baseline, "explicit render did not refresh task data")
vim.fn.delete(dir, "rf")
print("Startup responsiveness tests passed")
