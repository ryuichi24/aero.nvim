-- Run from the repository root: nvim --headless -u NONE -l tests/pull.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
dir = vim.fn.resolve(dir)
local remote, seed = dir .. "/remote.git", dir .. "/seed"
local repo, feature, local_only = dir .. "/checkout", dir .. "/feature tree", dir .. "/local tree"
local function git(args)
	local command = { "git", "-c", "user.name=Aero Test", "-c", "user.email=aero@example.invalid", "-c", "commit.gpgsign=false" }
	vim.list_extend(command, args)
	local result = vim.system(command, { text = true }):wait()
	assert(result.code == 0, (result.stderr or "") .. (result.stdout or ""))
	return vim.trim(result.stdout or "")
end
git({ "init", "--bare", "--initial-branch=main", remote })
git({ "init", "--initial-branch=main", seed })
vim.fn.writefile({ "initial" }, seed .. "/code.lua")
git({ "-C", seed, "add", "code.lua" })
git({ "-C", seed, "commit", "-m", "initial" })
git({ "-C", seed, "remote", "add", "origin", remote })
git({ "-C", seed, "branch", "feature" })
git({ "-C", seed, "push", "origin", "main", "feature" })
git({ "clone", remote, repo })
git({ "-C", repo, "worktree", "add", "-b", "feature", feature, "origin/feature" })
git({ "-C", repo, "worktree", "add", "-b", "local-only", local_only, "main" })
local initial = git({ "-C", repo, "rev-parse", "HEAD" })
git({ "-C", seed, "checkout", "feature" })
vim.fn.writefile({ "remote feature" }, seed .. "/code.lua")
git({ "-C", seed, "commit", "-am", "remote feature update" })
git({ "-C", seed, "push", "origin", "feature" })
local feature_head = git({ "-C", seed, "rev-parse", "HEAD" })
git({ "-C", seed, "checkout", "main" })
vim.fn.writefile({ "remote main" }, seed .. "/code.lua")
git({ "-C", seed, "commit", "-am", "remote main update" })
git({ "-C", seed, "push", "origin", "main" })
local main_head = git({ "-C", seed, "rev-parse", "HEAD" })

-- The last branch's empty tracking fields are trimmed from Git output.
local tracking
require("aero.git").remote_status(seed, function(statuses, err)
	assert(not err, err)
	tracking = statuses
end)
assert(vim.wait(5000, function()
	return tracking ~= nil
end, 10), "tracking status did not complete")
assert(tracking.main and not tracking.main.upstream, "last branch without upstream was omitted")
git({ "-C", seed, "branch", "--set-upstream-to=origin/main", "main" })
tracking = nil
require("aero.git").remote_status(seed, function(statuses, err)
	assert(not err, err)
	tracking = statuses
end)
assert(vim.wait(5000, function()
	return tracking ~= nil
end, 10), "tracking status did not complete")
assert(tracking.main and tracking.main.upstream and tracking.main.ahead == 0 and tracking.main.behind == 0)

local aero = require("aero")
local opts = { state_file = dir .. "/state.json", animation = false, start_insert = false }
aero.setup(vim.deepcopy(opts))
vim.cmd.runtime("plugin/aero.lua")
require("aero.store").add_workspace(repo)
vim.o.autoread = true
vim.cmd.edit(vim.fn.fnameescape(feature .. "/code.lua"))
local code, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
local cwd, tab = vim.fn.getcwd(), api.nvim_get_current_tabpage()
local old_notify, messages = vim.notify, {}
vim.notify = function(message, level)
	table.insert(messages, { text = message, level = level })
end
aero.open()
local dashboard_win = api.nvim_get_current_win()
local function await_status(branch, status)
	assert(vim.wait(5000, function()
		for _, text in ipairs(api.nvim_buf_get_lines(api.nvim_win_get_buf(dashboard_win), 0, -1, false)) do
			if text:find(" " .. branch, 1, true) and text:find(status, 1, true) then
				return true
			end
		end
	end, 10), "missing remote status for " .. branch .. ": " .. status)
end
await_status("feature", "[pull ↓1]")
await_status("main", "[pull ↓1]")
await_status("local-only", "[no upstream]")
assert(git({ "-C", feature, "rev-parse", "HEAD" }) == initial, "status check changed the checkout")
local function select(branch)
	api.nvim_set_current_win(dashboard_win)
	for line, text in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
		if text:find(" " .. branch, 1, true) then
			api.nvim_win_set_cursor(0, { line, 0 })
			return
		end
	end
	error("worktree row not found: " .. branch)
end
local function await_result(after, success)
	local found
	assert(vim.wait(5000, function()
		for i = after + 1, #messages do
			local message = messages[i]
			if message.text:find(success and "Aero: pulled " or "Aero: pull failed:", 1, true) then
				found = message
				return true
			end
		end
	end, 10), "pull did not report its result: " .. vim.inspect(messages))
	return found
end
select("feature")
local before = #messages
vim.cmd("Aero pull")
aero.pull() -- Must not launch a second concurrent pull.
assert(messages[#messages].text:find("already running", 1, true))
await_result(before, true)
await_status("feature", "[up to date]")
assert(git({ "-C", feature, "rev-parse", "HEAD" }) == feature_head, "selected worktree was not updated")
assert(git({ "-C", repo, "rev-parse", "HEAD" }) == initial, "pull updated the wrong checkout")
assert(api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "remote feature", "open file was not refreshed")
assert(vim.fn.getcwd() == cwd and api.nvim_get_current_tabpage() == tab and api.nvim_get_current_win() == dashboard_win)
assert(type(vim.fn.maparg("P", "n", false, true).callback) == "function")

-- A different shortcut should target the main worktree, not the previous selection.
opts.keymaps = { pull = "gp" }
aero.setup(vim.deepcopy(opts))
select("main (main)")
assert(vim.fn.maparg("P", "n", false, true).callback == nil)
before = #messages
api.nvim_feedkeys(api.nvim_replace_termcodes("gp", true, false, true), "xt", false)
await_result(before, true)
assert(git({ "-C", repo, "rev-parse", "HEAD" }) == main_head)
assert(git({ "-C", feature, "rev-parse", "HEAD" }) == feature_head)

-- Git's missing-upstream error is reported and the checkout remains unchanged.
select("local-only")
before = #messages
vim.cmd("Aero pull")
local failure = await_result(before, false)
assert(failure.level == vim.log.levels.ERROR and failure.text:find("tracking information", 1, true))
assert(git({ "-C", local_only, "rev-parse", "HEAD" }) == initial)

-- Divergence must not create a merge, and unsaved code must remain untouched.
git({ "-C", seed, "checkout", "feature" })
vim.fn.writefile({ "new remote feature" }, seed .. "/code.lua")
git({ "-C", seed, "commit", "-am", "another remote update" })
git({ "-C", seed, "push", "origin", "feature" })
vim.fn.writefile({ "local commit" }, feature .. "/local.txt")
git({ "-C", feature, "add", "local.txt" })
git({ "-C", feature, "commit", "-m", "local divergence" })
local diverged = git({ "-C", feature, "rev-parse", "HEAD" })
api.nvim_buf_set_lines(buf, 0, -1, false, { "unsaved code" })
select("feature")
before = #messages
vim.cmd("Aero pull")
failure = await_result(before, false)
assert(failure.text:find("fast-forward", 1, true))
await_status("feature", "[diverged ↑1 ↓1]")
assert(git({ "-C", feature, "rev-parse", "HEAD" }) == diverged)
assert(vim.bo[buf].modified and api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unsaved code")

opts.keymaps = { pull = false }
aero.setup(vim.deepcopy(opts))
assert(vim.fn.maparg("gp", "n", false, true).callback == nil)
api.nvim_win_set_cursor(dashboard_win, { 1, 0 })
before = #messages
aero.pull()
assert(messages[#messages].text:find("move the cursor to a worktree", 1, true) and #messages == before + 1)

-- The command still works with the shortcut disabled, outside the dashboard.
api.nvim_set_current_win(code)
vim.t.aero_worktree = repo
before = #messages
vim.cmd("Aero pull")
await_result(before, true)
assert(git({ "-C", repo, "rev-parse", "HEAD" }) == main_head)
assert(api.nvim_get_current_win() == code)
assert(vim.bo[buf].modified and api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "unsaved code")
vim.notify = old_notify
require("aero.buffers").flush()
vim.fn.delete(dir, "rf")
print("Pull tests passed (real remote, selected checkout, file refresh, duplicate guard, custom/disabled key, Git errors, code context).")
