-- Persistent state: the workspace list and the session definitions per worktree.
--
-- Several nvim instances may share the state file, so every change re-reads the file, applies
-- just that change and writes the result (see `update`); a stale in-memory copy never overwrites
-- another instance's changes. Writes go to a temp file that is renamed over the state file, so
-- a crash mid-write can't leave it truncated.
local config = require("aero.config")
local events = require("aero.events")

local M = {}

M.data = { workspaces = {}, sessions = {} }

local function read()
	local f = io.open(config.options.state_file, "r")
	if not f then
		return nil
	end
	local ok, data = pcall(vim.json.decode, f:read("*a"))
	f:close()
	if not (ok and type(data) == "table") then
		return nil
	end
	local workspaces = {}
	for _, ws in ipairs(type(data.workspaces) == "table" and data.workspaces or {}) do
		if type(ws) == "table" then
			-- Older state files stored the workspace directory as `path`, without a name.
			local root = ws.root or ws.path
			if type(root) == "string" and root ~= "" then
				root = vim.fs.normalize(root)
				table.insert(workspaces, {
					root = root,
					name = type(ws.name) == "string" and ws.name ~= "" and ws.name or vim.fs.basename(root),
					expanded = ws.expanded ~= false,
				})
			end
		end
	end
	return {
		workspaces = workspaces,
		sessions = type(data.sessions) == "table" and data.sessions or {},
	}
end

local function write(data)
	local path = config.options.state_file
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local out = { workspaces = data.workspaces, sessions = vim.empty_dict() }
	if config.options.persist_sessions then
		for wt, list in pairs(data.sessions) do
			if #list > 0 then
				out.sessions[wt] = list
			end
		end
	end
	local tmp = ("%s.%d.tmp"):format(path, vim.fn.getpid())
	local f, err = io.open(tmp, "w")
	if not f then
		vim.notify("aero: can't save state: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
	f:write(vim.json.encode(out))
	f:close()
	local ok, rerr = vim.uv.fs_rename(tmp, path)
	if not ok then
		os.remove(tmp)
		vim.notify("aero: can't save state: " .. tostring(rerr), vim.log.levels.ERROR)
	end
end

--- Pick up changes other instances saved. With persist_sessions off, sessions only live here.
function M.load()
	local data = read()
	if not data then
		return
	end
	M.data.workspaces = data.workspaces
	if config.options.persist_sessions then
		M.data.sessions = data.sessions
	end
end

--- Apply `fn` to the latest saved state and save it. The result becomes the in-memory state.
local function update(fn)
	M.load()
	local result = { fn(M.data) }
	write(M.data)
	return unpack(result)
end

function M.find_workspace(root)
	for i, ws in ipairs(M.data.workspaces) do
		if ws.root == root then
			return ws, i
		end
	end
end

function M.add_workspace(root)
	local ws, added = update(function()
		local ws = M.find_workspace(root)
		if ws then
			return ws, false
		end
		ws = { name = vim.fs.basename(root), root = root, expanded = true }
		table.insert(M.data.workspaces, ws)
		return ws, true
	end)
	if added then
		events.emit("workspace_added", { root = ws.root, name = ws.name })
	end
	return ws, added
end

function M.remove_workspace(root)
	local removed = update(function()
		local ws, i = M.find_workspace(root)
		if i then
			table.remove(M.data.workspaces, i)
			return ws
		end
	end)
	if removed then
		events.emit("workspace_removed", { root = removed.root, name = removed.name })
	end
end

function M.set_expanded(root, expanded)
	update(function()
		local ws = M.find_workspace(root)
		if ws then
			ws.expanded = expanded
		end
	end)
end

---@return {name: string, agent: string}[]
function M.sessions(worktree)
	return M.data.sessions[worktree] or {}
end

function M.find_session(worktree, name)
	for _, def in ipairs(M.data.sessions[worktree] or {}) do
		if def.name == name then
			return def
		end
	end
end

--- Add a session of `agent` to `worktree`, named `agent`, `agent-2`, … whichever is free
--- (also among sessions other instances added, and `taken(name)` if given).
---@return string name
function M.add_session(worktree, agent, taken)
	return update(function(data)
		local name, n = agent, 2
		while M.find_session(worktree, name) or (taken and taken(name)) do
			name, n = agent .. "-" .. n, n + 1
		end
		data.sessions[worktree] = data.sessions[worktree] or {}
		table.insert(data.sessions[worktree], { name = name, agent = agent })
		return name
	end)
end

--- Set an extra persisted field (e.g. the ACP session id) on a session definition.
function M.set_session_field(worktree, name, field, value)
	update(function()
		local def = M.find_session(worktree, name)
		if def then
			def[field] = value
		end
	end)
end

function M.remove_session(worktree, name)
	update(function(data)
		local list = data.sessions[worktree] or {}
		for i, def in ipairs(list) do
			if def.name == name then
				table.remove(list, i)
				break
			end
		end
		if #list == 0 then
			data.sessions[worktree] = nil
		end
	end)
end

return M
