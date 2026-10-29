-- Repository workflows receive explicit targets and report completed changes.
local config = require("aero.config")
local git = require("aero.git")
local store = require("aero.store")
local M = {}
local pulling = {}

local function notify(message, level)
	vim.notify("Aero: " .. message, level or vim.log.levels.INFO)
end

function M.add_workspace(path, changed)
	local function add(value)
		if not value or value == "" then
			return
		end

		local root, err = git.main_root(vim.fn.fnamemodify(vim.fn.expand(value), ":p"))

		if not root then
			return notify(err, vim.log.levels.ERROR)
		end

		local workspace, added = store.add_workspace(root)

		if not workspace then
			return
		end

		notify((added and "added " or "already added ") .. vim.fn.fnamemodify(root, ":~"))
		changed()
	end

	if path then
		return add(path)
	end

	vim.ui.input({ prompt = "Add workspace (git repo): ", default = vim.fn.getcwd(), completion = "dir" }, add)
end

function M.add_worktree(ws, changed)
	local function create(branch, remote)
		if not branch or vim.trim(branch) == "" then
			return
		end

		branch = vim.trim(branch)
		local default_path = config.options.worktree_path(ws, branch)
		vim.ui.input({ prompt = "Worktree name: ", default = vim.fs.basename(default_path) }, function(name)
			if not name or vim.trim(name) == "" then
				return
			end

			name = vim.trim(name)

			if name == "." or name == ".." or name:find("/", 1, true) then
				return notify("Worktree name must be a single directory name", vim.log.levels.WARN)
			end

			local path = vim.fs.joinpath(vim.fs.dirname(default_path), name)
			notify("creating worktree " .. name .. " (" .. branch .. ") …")
			git.add(ws.root, branch, path, function(ok, err)
				if not ok then
					return notify(err, vim.log.levels.ERROR)
				end

				store.set_expanded(ws.root, true)
				require("aero.submodules").invalidate(true)
				changed(ws, branch)
				notify("created " .. vim.fn.fnamemodify(path, ":~"))
			end, remote)
		end)
	end

	vim.ui.select({ "Create a new branch", "Check out an existing branch", "Check out a remote branch" }, {
		prompt = "Add worktree (" .. ws.name .. "):",
	}, function(choice)
		if choice == "Create a new branch" then
			vim.ui.input({ prompt = "New worktree branch (" .. ws.name .. "): " }, create)
		elseif choice == "Check out an existing branch" then
			git.branches(ws.root, function(branches, err)
				if not branches then
					return notify(err, vim.log.levels.ERROR)
				end

				local trees, list_err = git.list(ws.root)

				if not trees then
					return notify(list_err, vim.log.levels.ERROR)
				end

				local occupied, available = {}, {}

				for _, wt in ipairs(trees) do
					if wt.branch then
						occupied[wt.branch] = true
					end
				end

				for _, branch in ipairs(branches) do
					if not branch.remote and not occupied[branch.name] then
						table.insert(available, branch.name)
					end
				end

				if #available == 0 then
					return notify(
						"No available local branches; create a new branch or choose a remote branch",
						vim.log.levels.WARN
					)
				end

				vim.ui.select(available, { prompt = "Existing branch:" }, function(branch)
					create(branch)
				end)
			end)
		elseif choice == "Check out a remote branch" then
			git.remote_branches(ws.root, function(branches, err)
				if not branches then
					return notify(err, vim.log.levels.ERROR)
				end

				if #branches == 0 then
					return notify("No remote branches found; fetch the repository first", vim.log.levels.WARN)
				end

				vim.ui.select(branches, { prompt = "Remote branch:" }, function(remote)
					if remote then
						create(remote:match("^[^/]+/(.+)$"), remote)
					end
				end)
			end)
		end
	end)
end

function M.pull(path, changed)
	path = vim.fs.normalize(vim.fn.resolve(path))

	if pulling[path] then
		return notify("a pull is already running for " .. vim.fn.fnamemodify(path, ":~"), vim.log.levels.WARN)
	end

	pulling[path] = true
	notify("pulling " .. vim.fn.fnamemodify(path, ":~") .. " …")
	return git.pull(path, function(ok, output)
		pulling[path] = nil

		-- Failed fast-forwards may still have fetched new refs.
		require("aero.submodules").invalidate(true)
		require("aero.remote_status").invalidate()
		changed()

		if not ok then
			return notify("pull failed: " .. output, vim.log.levels.ERROR)
		end

		vim.cmd("checktime")
		notify("pulled " .. vim.fn.fnamemodify(path, ":~") .. (output ~= "" and ("\n" .. output) or ""))
	end)
end

function M.switch_branch(item, changed)
	if not item or not item.wt then
		return notify("move the cursor to a worktree first", vim.log.levels.WARN)
	end

	local path = item.wt.path
	git.branches(path, function(branches, err)
		if not branches then
			return notify(err, vim.log.levels.ERROR)
		end

		vim.ui.select(branches, {
			prompt = "Switch branch (" .. require("aero.dashboard.model").worktree_label(item.wt) .. "):",
			format_item = function(branch)
				return branch.name
					.. (branch.remote and " (remote)" or branch.name == item.wt.branch and " (current)" or "")
			end,
		}, function(branch)
			if not branch then
				return
			end

			git.switch_branch(path, branch, function(ok, switch_err)
				if not ok then
					return notify("branch switch failed: " .. switch_err, vim.log.levels.ERROR)
				end

				require("aero.submodules").invalidate(true)
				changed()
				vim.cmd("checktime")
				notify("switched " .. vim.fn.fnamemodify(path, ":~") .. " to " .. branch.name)
			end)
		end)
	end)
end

function M.delete(item, worktrees, changed)
	local sessions = require("aero.session")
	local buffers = require("aero.buffers")
	local ws = item.ws

	if item.kind == "worktree" then
		local wt = item.wt

		if wt.path == ws.root then
			return notify("refusing to remove the main worktree", vim.log.levels.WARN)
		end

		local choice =
			vim.fn.confirm("Remove worktree " .. vim.fn.fnamemodify(wt.path, ":~") .. "?", "&Yes\n&Force\n&No", 3)

		if choice ~= 1 and choice ~= 2 then
			return
		end

		git.remove(ws.root, wt.path, choice == 2, function(ok, err)
			if not ok then
				return notify(err .. (choice == 1 and " (use Force to remove anyway)" or ""), vim.log.levels.ERROR)
			end

			sessions.delete_worktree(wt.path)
			require("aero.terminal").delete(wt.path)
			local tabs = require("aero.tabs")

			if tabs.enabled() then
				tabs.close(wt.path)
			end

			buffers.forget(wt.path)
			require("aero.submodules").invalidate(true)
			notify("removed " .. vim.fn.fnamemodify(wt.path, ":~"))
			changed(ws)
		end)
	elseif item.kind == "workspace" then
		if vim.fn.confirm("Remove workspace " .. ws.name .. " from Aero? (files are kept)", "&Yes\n&No", 2) ~= 1 then
			return
		end

		for _, wt in ipairs(worktrees(ws).list or {}) do
			sessions.delete_worktree(wt.path)
			buffers.forget(wt.path)
		end

		if store.remove_workspace(ws.root) then
			changed(ws)
		end
	end
end

return M
