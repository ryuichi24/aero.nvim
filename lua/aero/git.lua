local M = {}
local events = require("aero.events")

local function run(args)
	local r = vim.system(args, { text = true }):wait()
	return r.code == 0, vim.trim(r.stdout or ""), vim.trim(r.stderr or "")
end

local function run_async(args, cb)
	vim.system(args, { text = true }, function(r)
		vim.schedule(function()
			cb(r.code == 0, vim.trim(r.stderr or ""))
		end)
	end)
end

---@class aero.Worktree
---@field path string
---@field head? string
---@field branch? string
---@field detached? boolean
---@field bare? boolean
---@field locked? boolean
---@field prunable? boolean

---@return aero.Worktree[]|nil, string|nil
function M.list(root)
	local ok, out, err = run({ "git", "-C", root, "worktree", "list", "--porcelain" })
	if not ok then
		return nil, err ~= "" and err or "not a git repository"
	end
	local list, cur = {}, nil
	for line in (out .. "\n"):gmatch("([^\n]*)\n") do
		local k, v = line:match("^(%S+)%s?(.*)$")
		if not k then
			cur = nil
		elseif k == "worktree" then
			cur = { path = v }
			table.insert(list, cur)
		elseif cur then
			if k == "HEAD" then
				cur.head = v
			elseif k == "branch" then
				cur.branch = v:gsub("^refs/heads/", "")
			elseif k == "detached" or k == "bare" or k == "locked" or k == "prunable" then
				cur[k] = true
			end
		end
	end
	return vim.tbl_filter(function(wt)
		return not wt.bare
	end, list)
end

--- Resolve any path inside a repository (or one of its worktrees) to the main worktree path.
function M.main_root(path)
	local ok, out, err = run({ "git", "-C", path, "worktree", "list", "--porcelain" })
	if not ok then
		return nil, err ~= "" and err or "not a git repository"
	end
	return out:match("^worktree ([^\n]+)")
end

local function branch_exists(root, branch)
	local ok, out = run({
		"git",
		"-C",
		root,
		"for-each-ref",
		"--format=%(refname)",
		"refs/heads/" .. branch,
		"refs/remotes/*/" .. branch,
	})
	return ok and out ~= ""
end

--- Create a worktree for `branch` at `path`, creating the branch from HEAD when it doesn't exist.
function M.add(root, branch, path, cb)
	local event_path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	local args = { "git", "-C", root, "worktree", "add" }
	if branch_exists(root, branch) then
		vim.list_extend(args, { path, branch })
	else
		vim.list_extend(args, { "-b", branch, path })
	end
	run_async(args, function(ok, err)
		cb(ok, err)
		if ok then
			events.emit("worktree_created", { root = root, branch = branch, path = event_path })
		end
	end)
end

function M.remove(root, path, force, cb)
	local args = { "git", "-C", root, "worktree", "remove", path }
	if force then
		table.insert(args, "--force")
	end
	run_async(args, function(ok, err)
		cb(ok, err)
		if ok then
			require("aero.buffers").forget(path)
			events.emit("worktree_removed", { root = root, path = path, force = force == true })
		end
	end)
end

return M
