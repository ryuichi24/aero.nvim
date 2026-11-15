-- Reconcile persisted session definitions with stable, process-local runtime identities.
-- Membership changes here never start/stop backends or write persisted state.
local store = require("aero.store")
local M = {}

---@type table<string, aero.Session>
local runtime = {}

local function key(worktree, name)
	return worktree .. "::" .. name
end

local function resolve(worktree, definition)
	local identity = definition.key or key(worktree, definition.name)

	if not runtime[identity] then
		runtime[identity] = {
			key = identity,
			worktree = worktree,
			name = definition.name,
			agent = definition.agent,
		}
	end

	local session = runtime[identity]
	session.name = definition.name
	return session
end

function M.get(worktree, name)
	local definition = store.find_session(worktree, name)
	return definition and resolve(worktree, definition)
end

function M.find(identity)
	return runtime[identity]
end

---@return aero.Session[]
function M.list(worktree)
	local sessions = {}

	for _, definition in ipairs(store.sessions(worktree)) do
		table.insert(sessions, resolve(worktree, definition))
	end

	return sessions
end

---@return aero.Session[]
function M.all()
	local sessions = {}

	for _, worktree in ipairs(store.session_worktrees()) do
		vim.list_extend(sessions, M.list(worktree))
	end

	return sessions
end

--- Already materialized sessions, including runtimes whose saved definitions disappeared.
--- Return a membership snapshot; the session objects themselves retain their identity.
---@return aero.Session[]
function M.loaded()
	return vim.tbl_values(runtime)
end

--- Reserve original identities after rename, even before a saved session is materialized.
function M.identity_taken(worktree, name)
	local identity = key(worktree, name)

	if runtime[identity] then
		return true
	end

	for _, definition in ipairs(store.sessions(worktree)) do
		if definition.key == identity then
			return true
		end
	end

	return false
end

function M.remove(identity)
	runtime[identity] = nil
end

--- Transcript/terminal ownership only; prompt buffers use aero_chat_key separately.
function M.from_buf(buf)
	local identity = vim.b[buf or 0].aero_session
	return identity and M.find(identity)
end

return M
