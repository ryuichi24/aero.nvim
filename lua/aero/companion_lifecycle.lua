-- Lifecycle actions share the companion's operation receipts and process epoch.
local M = {}

function M.target(epoch, wt)
	return vim.fn.sha256(vim.json.encode({ epoch, wt.path, wt.head or false, wt.branch or false }))
end

local function name(value)
	return type(value) == "string" and #value <= 256 and vim.trim(value) ~= "" and not value:find("%c")
end

function M.run(method, p, sessions, finish)
	local session = require("aero.session")
	local store = require("aero.store")
	local git = require("aero.git")
	local config = require("aero.config").options
	local selected
	for _, s in ipairs(sessions) do
		if s.key == p.session then
			selected = s
		end
	end
	if method:match("^session_") and method ~= "session_create" then
		if not selected then
			return finish(nil, "session unavailable")
		end
		if method == "session_rename" then
			if not name(p.name) then
				return finish(nil, "invalid session name")
			end
			local ok, err = session.rename(selected, vim.trim(p.name))
			return finish(ok and { status = "accepted" } or nil, err)
		elseif method == "session_delete" then
			session.delete(selected)
			return finish({ status = "accepted" })
		elseif method == "session_resume" then
			local agent = config.agents[selected.agent]
			if not agent or agent.type ~= "acp" then
				return finish(nil, "ACP agent required")
			end
			if not session.is_running(selected) and not session.start(selected, nil, not selected.fresh) then
				return finish(nil, "could not start agent")
			end
			return finish({ status = "accepted", session = selected.key })
		end
	end
	local ws = store.find_workspace(p.workspace)
	if not ws then
		return finish(nil, "workspace unavailable")
	end
	local wt
	for _, item in ipairs(git.list(ws.root) or {}) do
		if item.path == p.worktree then
			wt = item
		end
	end
	if method == "session_create" then
		if not wt then
			return finish(nil, "worktree unavailable")
		end
		local agent = config.agents[p.agent]
		if not agent or agent.type ~= "acp" then
			return finish(nil, "ACP agent required")
		end
		if p.name ~= nil and not name(p.name) then
			return finish(nil, "invalid session name")
		end
		local s, err = session.create(wt.path, p.agent, p.name and vim.trim(p.name))
		if not s then
			return finish(nil, err)
		end
		if not session.start(s, nil, false) then
			return finish(nil, "session created but agent could not start")
		end
		return finish({ status = "accepted", session = s.key })
	end
	if method ~= "worktree_create" and not wt then
		return finish(nil, "worktree unavailable")
	end
	if method ~= "worktree_create" and p.target ~= M.target(p.epoch, wt) then
		return finish(nil, "stale worktree")
	end
	if method == "worktree_rename" then
		if not wt.branch then
			return finish(nil, "detached worktree has no branch to rename")
		end
		if not name(p.name) or vim.trim(p.name):sub(1, 1) == "-" then
			return finish(nil, "invalid branch name")
		end
		local r = vim.system({ "git", "-C", wt.path, "branch", "-m", vim.trim(p.name) }, { text = true }):wait()
		return finish(r.code == 0 and { status = "accepted" } or nil, r.code ~= 0 and vim.trim(r.stderr) or nil)
	end
	local done = false
	finish({ status = "unknown" })
	local function complete(ok, err)
		if ok and method == "worktree_delete" then
			session.delete_worktree(wt.path)
			require("aero.terminal").delete(wt.path)
			if require("aero.tabs").enabled() then
				require("aero.tabs").close(wt.path)
			end
		end
		finish(ok and { status = "accepted" } or nil, not ok and err or nil)
		done = true
	end
	if method == "worktree_create" then
		if not name(p.branch) or vim.trim(p.branch):sub(1, 1) == "-" then
			return finish(nil, "invalid branch name")
		end
		local branch = vim.trim(p.branch)
		git.add(ws.root, branch, config.worktree_path(ws, branch), complete)
	elseif method == "worktree_delete" then
		if wt.path == ws.root then
			return finish(nil, "refusing to remove the main worktree")
		end
		git.remove(ws.root, wt.path, p.force == true, complete)
	end
	-- Long Git operations keep their receipt; an identical retry reads the final result.
	vim.wait(3500, function()
		return done
	end, 10)
end

return M
