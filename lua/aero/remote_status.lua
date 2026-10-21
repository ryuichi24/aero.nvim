-- Dashboard remote checks are independent of local worktree discovery.
local M = {}
local entries, queue = {}, {}
local active, scheduled = 0, false

local function now()
	return vim.uv.hrtime() / 1e6
end

local pump
local function schedule()
	if scheduled then
		return
	end
	scheduled = true
	vim.schedule(function()
		scheduled = false
		pump()
	end)
end

pump = function()
	local limit = math.max(1, require("aero.config").options.dashboard.remote_concurrency)
	while active < limit and #queue > 0 do
		local request = table.remove(queue, 1)
		local entry = request.entry
		active = active + 1
		require("aero.git").remote_status(request.root, function(statuses, err)
			active = active - 1
			entry.checking = false
			entry.completed = now()
			entry.fetch_err = err
			if statuses then
				entry.statuses = statuses
			end
			local listeners = entry.listeners
			entry.listeners = {}
			for _, listener in pairs(listeners) do
				listener(entry)
			end
			schedule()
		end)
	end
end

function M.request(root, callback)
	local entry = entries[root]
	if not entry then
		entry = { listeners = {} }
		entries[root] = entry
	end
	local interval = require("aero.config").options.dashboard.remote_refresh_interval
	if not entry.checking and (not entry.completed or now() - entry.completed >= interval) then
		entry.checking = true
		table.insert(queue, { root = root, entry = entry })
		schedule()
	end
	if entry.checking then
		entry.listeners[callback] = callback
	end
	return entry
end

function M.peek(root)
	return entries[root] or {}
end

-- Explicit refreshes bypass freshness, but still share queued/in-flight checks.
function M.invalidate()
	for _, entry in pairs(entries) do
		entry.completed = nil
	end
end

return M
