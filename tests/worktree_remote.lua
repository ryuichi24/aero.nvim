-- Run: nvim --headless -u NONE -l tests/worktree_remote.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local function git(args)
	local command =
		{ "git", "-c", "user.name=Aero Test", "-c", "user.email=aero@example.invalid", "-c", "commit.gpgsign=false" }
	vim.list_extend(command, args)
	local result = vim.system(command, { text = true }):wait()

	assert(result.code == 0, result.stderr)

	return vim.trim(result.stdout or "")
end

local seed, repo, remote = dir .. "/seed", dir .. "/repo", dir .. "/remote.git"
git({ "init", "--bare", "--initial-branch=main", remote })
git({ "init", "--initial-branch=main", seed })
git({ "-C", seed, "commit", "--allow-empty", "-m", "initial" })
git({ "-C", seed, "checkout", "-b", "feature/nested" })
git({ "-C", seed, "commit", "--allow-empty", "-m", "feature" })
git({ "-C", seed, "remote", "add", "origin", remote })
git({ "-C", seed, "push", "origin", "main", "feature/nested" })
git({ "clone", remote, repo })
local aero_git = require("aero.git")
local branches
aero_git.remote_branches(repo, function(result, err)
	assert(result, err)

	branches = result
end)

assert(vim.wait(5000, function()
	return branches ~= nil
end))
assert(vim.deep_equal(branches, { "origin/feature/nested", "origin/main" }), vim.inspect(branches))

local function add(branch, path, ref)
	local done = false
	aero_git.add(repo, branch, path, function(ok, err)
		assert(ok, err)

		done = true
	end, ref)

	assert(vim.wait(5000, function()
		return done
	end))
end

local path = dir .. "/feature tree"
add("feature/nested", path, "origin/feature/nested")

assert(git({ "-C", path, "branch", "--show-current" }) == "feature/nested")
assert(git({ "-C", path, "rev-parse", "HEAD" }) == git({ "-C", seed, "rev-parse", "HEAD" }))
assert(git({ "-C", path, "rev-parse", "--abbrev-ref", "@{upstream}" }) == "origin/feature/nested")

git({ "-C", repo, "worktree", "remove", path })
add("feature/nested", path, "origin/feature/nested")
add("new-branch", dir .. "/new tree")

assert(git({ "-C", dir .. "/new tree", "rev-parse", "HEAD" }) == git({ "-C", repo, "rev-parse", "HEAD" }))

local choices
aero_git.branches(path, function(result, err)
	assert(result, err)

	choices = result
end)

assert(vim.wait(5000, function()
	return choices ~= nil
end))
assert(vim.iter(choices):any(function(branch)
	return branch.name == "feature/nested" and not branch.remote
end))
assert(not vim.iter(choices):any(function(branch)
	return branch.name == "origin/HEAD"
end))

local function switch(branch, expected)
	local done = false
	aero_git.switch_branch(path, branch, function(ok, err)
		assert(ok == expected, err)

		done = true
	end)

	assert(vim.wait(5000, function()
		return done
	end))
end

git({ "-C", repo, "branch", "available" })
switch({ name = "available" }, true)

assert(git({ "-C", path, "branch", "--show-current" }) == "available")
assert(git({ "-C", repo, "branch", "--show-current" }) == "main")

switch({ name = "main" }, false)

assert(git({ "-C", path, "branch", "--show-current" }) == "available")

git({ "-C", seed, "push", "origin", "HEAD:remote-only" })
git({ "-C", repo, "fetch", "origin" })
switch({ name = "origin/remote-only", remote = "origin/remote-only" }, true)

assert(git({ "-C", path, "rev-parse", "--abbrev-ref", "@{upstream}" }) == "origin/remote-only")

vim.fn.delete(dir, "rf")
print("remote worktree tests passed")
