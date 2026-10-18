-- Read-only, asynchronous Git queries for worktree review. No editor effects.
local M = {}
local limit = 1024 * 1024

local function run(path, args, callback, accepted)
	local command = { "git", "--no-optional-locks", "--literal-pathspecs", "-C", path }
	vim.list_extend(command, args)
	local chunks, size, truncated = {}, 0, false
	return vim.system(command, {
		-- Keep NUL-delimited filenames byte-for-byte (including embedded CR/LF).
		text = false,
		timeout = 10000,
		stdout = function(_, data)
			if not data then return end
			if size < limit then table.insert(chunks, data:sub(1, limit - size)) end
			size = size + #data
			truncated = size > limit
		end,
	}, function(result)
		vim.schedule(function()
			if result.code ~= 0 and not (accepted and accepted[result.code]) then
				callback(nil, vim.trim(result.stderr or "") ~= "" and vim.trim(result.stderr)
					or ("Git exited with code " .. result.code))
			else
				callback(table.concat(chunks), nil, truncated)
			end
		end)
	end)
end

local function records(output, kind)
	local fields = vim.split(output, "\0", { plain = true, trimempty = true })
	local items, i = {}, 1
	while i <= #fields do
		local status, path, old_path = fields[i], fields[i + 1], nil
		if status:match("^[RC]") then
			old_path, path = path, fields[i + 2]
			i = i + 1
		end
		if not path then return nil, "incomplete Git change list" end
		table.insert(items, { kind = kind, status = status, path = path, old_path = old_path })
		i = i + 2
	end
	return items
end

--- Local and remote branches, excluding symbolic aliases such as origin/HEAD.
function M.branches(path, callback)
	run(path, { "for-each-ref", "--sort=refname", "--format=%(refname:short)%09%(symref)", "refs/heads", "refs/remotes" }, function(out, err, truncated)
		if not out or truncated then return callback(nil, err or "branch list exceeds 1 MiB") end
		local branches = {}
		for line in out:gmatch("[^\n]+") do
			local name, symbolic = line:match("^(.-)\t(.*)$")
			if name and symbolic == "" then table.insert(branches, name) end
		end
		callback(branches)
	end)
end

--- base=nil reviews index/worktree separately; base=ref reviews committed branch changes only.
function M.collect(path, base, callback)
	run(path, { "rev-parse", "--show-toplevel" }, function(root, err)
		if not root then return callback(nil, err) end
		root = root:gsub("\n$", "")
		local snapshot = { worktree = root, base = base, items = {}, refreshed = os.date("%Y-%m-%d %H:%M:%S") }
		local function list_branch(merge_base)
			snapshot.merge_base = merge_base
			run(root, { "diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "--find-renames", merge_base, snapshot.head, "--" }, function(out, list_err, truncated)
				if not out or truncated then return callback(nil, list_err or "change list exceeds 1 MiB") end
				snapshot.items, list_err = records(out, "branch")
				if not snapshot.items then return callback(nil, list_err) end
				callback(snapshot)
			end)
		end
		if base then
			-- Resolve first: refs starting with '-' cannot become command options.
			return run(root, { "rev-parse", "--verify", "--end-of-options", base .. "^{commit}" }, function(ref, ref_err)
				if not ref then return callback(nil, ref_err) end
				run(root, { "rev-parse", "--verify", "HEAD" }, function(head, head_err)
					if not head then return callback(nil, head_err) end
					snapshot.head = vim.trim(head)
					run(root, { "merge-base", snapshot.head, vim.trim(ref) }, function(ancestor, merge_err)
						if not ancestor then return callback(nil, merge_err) end
						list_branch(vim.trim(ancestor))
					end)
				end)
			end)
		end
		local queries = {
			{ kind = "staged", args = { "diff", "--cached", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "--find-renames", "--" } },
			{ kind = "unstaged", args = { "diff", "--no-ext-diff", "--no-textconv", "--name-status", "-z", "--find-renames", "--" } },
			{ kind = "untracked", args = { "ls-files", "--others", "--exclude-standard", "-z" } },
		}
		local function next_query(index)
			local query = queries[index]
			if not query then return callback(snapshot) end
			run(root, query.args, function(out, query_err, truncated)
				if not out or truncated then return callback(nil, query_err or "change list exceeds 1 MiB") end
				local items
				if query.kind == "untracked" then
					items = {}
					for _, name in ipairs(vim.split(out, "\0", { plain = true, trimempty = true })) do
						table.insert(items, { kind = "untracked", status = "?", path = name })
					end
				else
					items, query_err = records(out, query.kind)
				end
				if not items then return callback(nil, query_err) end
				vim.list_extend(snapshot.items, items)
				next_query(index + 1)
			end)
		end
		next_query(1)
	end)
end

function M.diff(snapshot, item, callback)
	local args = { "diff", "--no-ext-diff", "--no-textconv", "--no-color", "--find-renames" }
	if item.kind == "untracked" then
		vim.list_extend(args, { "--no-index", "--", "/dev/null", item.path })
	else
		if item.kind == "staged" then table.insert(args, "--cached") end
		if item.kind == "branch" then vim.list_extend(args, { snapshot.merge_base, snapshot.head }) end
		table.insert(args, "--")
		if item.old_path then table.insert(args, item.old_path) end
		table.insert(args, item.path)
	end
	return run(snapshot.worktree, args, callback, item.kind == "untracked" and { [1] = true } or nil)
end

return M
