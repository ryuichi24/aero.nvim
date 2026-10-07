local M = {}
local events = require("aero.events")

local function run(args)
	local r = vim.system(args, { text = true }):wait()
	return r.code == 0, vim.trim(r.stdout or ""), vim.trim(r.stderr or "")
end

local function run_async(args, cb)
	return vim.system(args, { text = true }, function(r)
		vim.schedule(function()
			cb(r.code == 0, vim.trim(r.stderr or ""), vim.trim(r.stdout or ""))
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

--- List remote branches, excluding symbolic refs such as origin/HEAD.
function M.remote_branches(root, cb)
	run_async({ "git", "-C", root, "for-each-ref", "--format=%(refname)\t%(symref)", "refs/remotes/" }, function(ok, err, out)
		if not ok then
			return cb(nil, err)
		end
		local branches = {}
		for line in out:gmatch("[^\n]+") do
			local ref, symbolic = line:match("^([^\t]+)\t(.*)$")
			ref = ref or line
			if not symbolic or symbolic == "" then
				table.insert(branches, (ref:gsub("^refs/remotes/", "")))
			end
		end
		cb(branches)
	end)
end

--- Create a worktree, optionally creating a tracking branch from an explicit remote ref.
function M.add(root, branch, path, cb, remote)
	local event_path = vim.fs.normalize(vim.fn.fnamemodify(path, ":p"))
	local args = { "git", "-C", root, "worktree", "add" }
	if remote then
		local exists = run({ "git", "-C", root, "show-ref", "--verify", "--quiet", "refs/heads/" .. branch })
		if exists then
			vim.list_extend(args, { path, branch })
		else
			vim.list_extend(args, { "--track", "-b", branch, path, "refs/remotes/" .. remote })
		end
	elseif branch_exists(root, branch) then
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

--- Fetch remote refs without changing any checkout, then read tracking status for all branches.
function M.remote_status(root, cb)
	run_async({ "git", "-C", root, "fetch", "--all", "--prune" }, function(ok, err)
		if not ok then
			cb(nil, err ~= "" and err or "fetch failed")
			return
		end
		run_async({ "git", "-C", root, "for-each-ref", "--format=%(refname:short)\t%(upstream)\t%(upstream:track)", "refs/heads/" }, function(read_ok, read_err, out)
			if not read_ok then
				cb(nil, read_err ~= "" and read_err or "tracking status failed")
				return
			end
			local statuses = {}
			for line in out:gmatch("[^\n]+") do
				local fields = vim.split(line, "\t", { plain = true })
				local branch, upstream, track = fields[1], fields[2] or "", fields[3] or ""
				if branch then
					statuses[branch] = {
						upstream = upstream ~= "" and upstream or nil,
						gone = track == "[gone]",
						ahead = tonumber(track:match("ahead (%d+)")) or 0,
						behind = tonumber(track:match("behind (%d+)")) or 0,
					}
				end
			end
			cb(statuses)
		end)
	end)
end

--- Pull the checkout's configured upstream, fast-forwarding without a merge commit.
function M.pull(path, cb)
	return run_async({ "git", "-C", path, "pull", "--ff-only" }, function(ok, err, out)
		local output = out
		if err ~= "" then
			output = output ~= "" and (output .. "\n" .. err) or err
		end
		cb(ok, output)
	end)
end

return M
