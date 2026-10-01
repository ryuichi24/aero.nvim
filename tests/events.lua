-- Run from the repository root: nvim --headless -u NONE -l tests/events.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local aero = require("aero")
local events = require("aero.events")
local api = vim.api

local order = {}
local unsubscribe = aero.on("probe", function(ev)
	table.insert(order, "first")
	ev.path = "mutated"
end)
local once = 0
aero.once("probe", function(ev)
	once = once + 1
	assert(ev.path == "original", "one handler mutated another's payload")
	table.insert(order, "once")
	events.emit("probe", { path = "original" })
end)
local wildcard = aero.on("*", function(ev)
	assert(ev.event == "probe")
	table.insert(order, "wildcard")
end)
events.emit("probe", { path = "original" })
assert(once == 1, "once listener was called recursively")
assert(table.concat(order, ",") == "first,once,first,wildcard,wildcard")
unsubscribe()
wildcard()
local removed = function()
	error("off did not unsubscribe")
end
aero.on("probe", removed)
aero.off("probe", removed)
events.emit("probe", {})

-- A callback failure does not stop later handlers or native User autocmds.
local notices, native, following = {}, 0, 0
local notify = vim.notify
vim.notify = function(message)
	table.insert(notices, message)
end
aero.on("failure_probe", function()
	error("intentional handler error")
end)
aero.on("failure_probe", function()
	following = following + 1
end)
api.nvim_create_autocmd("User", {
	pattern = "AeroFailureProbe",
	callback = function(ev)
		assert(ev.data.event == "failure_probe" and ev.data.value == 42)
		native = native + 1
	end,
})
events.emit("failure_probe", { value = 42 })
vim.wait(50)
vim.notify = notify
assert(following == 1 and native == 1 and #notices == 1)

-- Fast-event dispatch is scheduled onto Neovim's main thread.
local fast = false
aero.once("fast_probe", function()
	assert(not vim.in_fast_event())
	fast = true
end)
local timer = vim.uv.new_timer()
timer:start(1, 0, function()
	events.emit("fast_probe", {})
	timer:close()
end)
assert(vim.wait(1000, function()
	return fast
end, 10))

local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/repo", "p")
dir = vim.fn.resolve(dir)
local root, path = dir .. "/repo", dir .. "/worktree with spaces"
local function git(args, stdin)
	local cmd = { "git", "-C", root }
	vim.list_extend(cmd, args)
	local result = vim.system(cmd, { stdin = stdin, text = true }):wait()
	assert(result.code == 0, result.stderr)
	return vim.trim(result.stdout)
end
-- An isolated fixture repository: no changes to the user's repository or git configuration.
git({ "init", "--quiet" })
local tree = git({ "hash-object", "-t", "tree", "-w", "--stdin" }, "")
local commit = git(
	{ "hash-object", "-t", "commit", "-w", "--stdin" },
	"tree "
		.. tree
		.. "\nauthor Aero Test <test@example.com> 1 +0000\ncommitter Aero Test <test@example.com> 1 +0000\n\nfixture\n"
)
git({ "update-ref", "refs/heads/main", commit })
git({ "symbolic-ref", "HEAD", "refs/heads/main" })

local setup, manual, old = 0, 0, 0
local stop_setup = aero.on("setup", function()
	manual = manual + 1
end)
aero.setup({
	state_file = dir .. "/state.json",
	fullscreen_key = false,
	events = {
		setup = function()
			old = old + 1
		end,
	},
})
local created, removed_count, callback_done, oil_path, oil_win = 0, 0, false
package.preload["oil"] = function()
	return {
		open = function(p)
			oil_path, oil_win = p, api.nvim_get_current_win()
			local buf = api.nvim_create_buf(false, true)
			vim.bo[buf].filetype = "oil"
			api.nvim_win_set_buf(oil_win, buf)
		end,
	}
end
aero.setup({
	state_file = dir .. "/state.json",
	animation = false,
	fullscreen_key = false,
	events = {
		setup = function()
			setup = setup + 1
		end,
		worktree_created = function(ev)
			assert(callback_done, "creation event ran before dashboard completion callback")
			assert(ev.root == root and ev.branch == "feature" and ev.path == path)
			assert(vim.fn.isdirectory(ev.path) == 1)
			created = created + 1
			aero.open_worktree(ev.path, function(p)
				require("oil").open(p)
			end)
		end,
		worktree_removed = function(ev)
			assert(ev.path == path and vim.fn.isdirectory(path) == 0)
			removed_count = removed_count + 1
		end,
	},
})
assert(old == 1 and setup == 1 and manual == 2, "setup handlers accumulated or manual handler was lost")
stop_setup()

local added, removed_workspace = 0, 0
aero.on("workspace_added", function(ev)
	assert(ev.root == root)
	added = added + 1
end)
aero.on("workspace_removed", function(ev)
	assert(ev.root == root)
	removed_workspace = removed_workspace + 1
end)
aero.add_workspace(root)
aero.add_workspace(root)
assert(added == 1)
aero.open()
local dashboard_win = api.nvim_get_current_win()
require("aero.git").add(root, "feature", path, function(ok, err)
	assert(ok, err)
	callback_done = true
end)
assert(vim.wait(5000, function()
	return created == 1
end, 10))
assert(oil_path == path and oil_win ~= dashboard_win, "Oil replaced the dashboard instead of the code pane")
assert(vim.bo[api.nvim_win_get_buf(dashboard_win)].filetype == "Aero")
assert(vim.fn.getcwd() == path)
assert(vim.bo[api.nvim_get_current_buf()].filetype == "oil")

local failed = false
require("aero.git").add(root, "other", path, function(ok)
	assert(not ok)
	failed = true
end)
assert(vim.wait(5000, function()
	return failed
end, 10))
assert(created == 1, "failed worktree creation emitted success")
require("aero.git").remove(root, path, false, function(ok, err)
	assert(ok, err)
	require("aero.tabs").close(path)
end)
assert(vim.wait(5000, function()
	return removed_count == 1
end, 10))
require("aero.store").remove_workspace(root)
assert(removed_workspace == 1)

local lifecycle = {}
for _, name in ipairs({ "session_created", "session_started", "session_shown", "session_exited", "session_deleted" }) do
	aero.on(name, function(ev)
		assert(ev.agent == "fixture" and ev.worktree == root)
		table.insert(lifecycle, ev.event)
	end)
end
require("aero.config").options.agents.fixture = { cmd = { "sh", "-c", "printf 'done\\n'" } }
local sessions = require("aero.session")
local s = sessions.create(root, "fixture")
api.nvim_set_current_win(api.nvim_tabpage_list_wins(0)[1])
assert(sessions.show(s, 0))
assert(vim.wait(5000, function()
	return s.exit_code ~= nil
end, 10))
sessions.delete(s)
assert(table.concat(lifecycle, ",") == "session_created,session_started,session_shown,session_exited,session_deleted")

local stopped = 0
local off_stopped = aero.on("session_stopped", function(ev)
	assert(ev.key and ev.name and ev.agent == "fixture")
	stopped = stopped + 1
end)
require("aero.config").options.agents.fixture = { cmd = { "cat" } }
local running = sessions.create(root, "fixture")
assert(sessions.show(running, 0))
sessions.stop(running)
sessions.stop(running)
assert(stopped == 1, "duplicate stop-request event")
assert(vim.wait(5000, function()
	return running.exit_code ~= nil
end, 10))
sessions.delete(running)
off_stopped()

vim.cmd.tcd(vim.fn.fnameescape(vim.fn.getcwd(-1, 0)))
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print("Event tests passed (dispatch, subscriptions, Git lifecycle, Oil targeting, session lifecycle).")
