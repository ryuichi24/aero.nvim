-- Snapshot polling must return while worktree discovery is still in flight.
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
require("aero").setup({ state_file = dir .. "/state.json", animation = false })
local store = require("aero.store")
store.add_workspace(vim.fn.getcwd())
local git = require("aero.git")
local original_list, original_async = git.list, git.list_async
local pending, calls = nil, 0
git.list = function()
	error("snapshot blocked on synchronous Git")
end
git.list_async = function(_, callback)
	calls = calls + 1
	pending = callback
end
local bridge = require("aero.companion")
local initial = bridge.dispatch("snapshot")

assert(pending and calls == 1, "snapshot did not start background discovery")
assert(initial.worktrees[1].path == vim.fn.getcwd(), "initial snapshot lost the workspace")

bridge.dispatch("snapshot")

assert(calls == 1, "polling duplicated in-flight discovery")

pending({ { path = vim.fn.getcwd(), branch = "performance-test" } })
local refreshed = bridge.dispatch("snapshot")

assert(refreshed.worktrees[1].branch == "performance-test", "snapshot ignored background result")

local original_now = vim.uv.now
local later = original_now() + 5001
vim.uv.now = function()
	return later
end
local stale = bridge.dispatch("snapshot")

assert(calls == 2 and stale.worktrees[1].branch == "performance-test", "refresh discarded the last known worktrees")

later = later + 5001
bridge.dispatch("snapshot")

assert(calls == 2, "expired polling duplicated a slow discovery")

pending(nil, "Git unavailable")

assert(
	bridge.dispatch("snapshot").worktrees[1].branch == "performance-test",
	"failed refresh discarded cached worktrees"
)

vim.uv.now = original_now
git.list, git.list_async = original_list, original_async
local completed = false
git.list_async(vim.fn.getcwd(), function(list, err)
	assert(list and not err and #list > 0, "asynchronous Git discovery failed")
	assert(not vim.in_fast_event(), "discovery callback cannot safely update editor state")

	completed = true
end)

assert(not completed, "Git discovery completed synchronously")
assert(
	vim.wait(5000, function()
		return completed
	end, 10),
	"background Git discovery timed out"
)

vim.fn.delete(dir, "rf")
print("companion performance: ok")
vim.cmd("qa!")
