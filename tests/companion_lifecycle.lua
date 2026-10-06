vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/repo", "p")
dir = assert(vim.uv.fs_realpath(dir))
local root = dir .. "/repo"
local function git(...)
	local r = vim.system(vim.list_extend({ "git", "-C", root }, { ... }), { text = true }):wait()
	assert(r.code == 0, r.stderr)
end
git("init", "-b", "main")
git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "--allow-empty", "-m", "initial")
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	agents = { fixture = { type = "acp", cmd = { "python3", vim.fn.getcwd() .. "/tests/fixtures/companion_acp.py" } } },
	worktree_path = function(_, branch)
		return dir .. "/" .. branch
	end,
})
local store, sessions, bridge = require("aero.store"), require("aero.session"), require("aero.companion")
store.add_workspace(root)
local epoch = bridge.dispatch("snapshot").epoch
assert(vim.tbl_contains(bridge.dispatch("snapshot").agents, "fixture"))
local n = 0
local function action(method, extra)
	n = n + 1
	local p = vim.tbl_extend(
		"force",
		{ operation_id = ("lifecycle-%08d"):format(n), epoch = epoch, workspace = root },
		extra or {}
	)
	if method == "worktree_rename" or method == "worktree_delete" then
		for _, wt in ipairs(bridge.dispatch("snapshot").worktrees) do
			if wt.path == p.worktree then
				p.target = wt.target
			end
		end
	end
	local result, err = bridge.dispatch(method, p)
	return result, err, p
end
local result, err, request = action("worktree_create", { branch = "feature" })
assert(result and result.status == "accepted", err)
assert(bridge.dispatch("worktree_create", request).status == "accepted")
local reused = vim.tbl_extend("force", request, { branch = "other" })
local rejected, reason = bridge.dispatch("worktree_create", reused)
assert(not rejected and reason:find("different arguments"))
assert(#require("aero.git").list(root) == 2)
local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
result, err, request = action("session_create", { worktree = dir .. "/feature", agent = "fixture", name = "Phone" })
assert(result and result.status == "accepted", err)
assert(bridge.dispatch("session_create", request).session == result.session)
assert(#sessions.all() == 1)
assert(
	vim.api.nvim_get_current_win() == win and vim.api.nvim_get_current_buf() == buf,
	"remote startup changed host window"
)
local s = sessions.all()[1]
assert(vim.wait(5000, function()
	return s.chat.state == "ready"
end, 10))
s.chat.state = "starting"
assert(bridge.dispatch("snapshot").sessions[1].status == "starting", "initializing agents must not appear ready")
s.chat.state = "ready"
local target = bridge.dispatch("snapshot").sessions[1].target
result, err = action("session_rename", { session = s.key, target = target, name = "Renamed" })
assert(result and s.name == "Renamed", err)
sessions.stop(s)
assert(vim.wait(5000, function()
	return s.chat.state == "exited"
end, 10))
result, err, request = action("session_resume", { session = s.key, target = target })
assert(result and result.status == "accepted", err)
local chat = s.chat
assert(bridge.dispatch("session_resume", request).status == "accepted" and s.chat == chat)
assert(vim.wait(5000, function()
	return s.chat.state == "ready"
end, 10))
result, err = action("worktree_rename", { worktree = dir .. "/feature", name = "renamed-branch" })
assert(result and result.status == "accepted", err)
assert(require("aero.git").list(root)[2].branch == "renamed-branch")
result, err = bridge.dispatch("worktree_delete", {
	operation_id = "stale-worktree-00001",
	epoch = epoch,
	workspace = root,
	worktree = dir .. "/feature",
	target = "stale",
})
assert(not result and err == "stale worktree")
result, err = action("worktree_delete", { worktree = root })
assert(not result and err:find("main worktree"))
result, err = action("session_delete", { session = s.key, target = "stale" })
assert(not result and err == "stale session")
result, err = action("session_delete", { session = s.key, target = target })
assert(result and #sessions.all() == 0, err)
result, err = action("session_create", { worktree = dir .. "/feature", agent = "fixture", name = "Phone" })
assert(result, err)
vim.fn.writefile({ "dirty" }, dir .. "/feature/untracked")
result, err = action("worktree_delete", { worktree = dir .. "/feature" })
assert(not result and err and #sessions.all() == 1, "failed removal deleted sessions")
result, err, request = action("worktree_delete", { worktree = dir .. "/feature", force = true })
assert(result and result.status == "accepted" and #sessions.all() == 0, err)
assert(bridge.dispatch("worktree_delete", request).status == "accepted")
result, err = action("worktree_create", { epoch = "old-host", branch = "stale" })
assert(not result and err == "stale host epoch")
vim.fn.delete(dir, "rf")
print("companion lifecycle: ok")
vim.cmd("qa!")
