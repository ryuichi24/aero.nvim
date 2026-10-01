-- Ordered, error-isolated lifecycle hooks. Registration does not require setup().
local M = {}
local listeners = {}
local configured = {}

local function valid(name)
	assert(type(name) == "string" and (name == "*" or name:match("^[a-z][a-z0-9_]*$")), "aero: invalid event name")
end

--- Register a callback; the returned function unsubscribes this registration.
function M.on(name, callback, opts)
	valid(name)
	assert(type(callback) == "function", "aero: event handler must be a function")
	local item = { name = name, callback = callback, once = opts and opts.once, active = true }
	table.insert(listeners, item)
	return function()
		item.active = false
	end
end

function M.once(name, callback)
	return M.on(name, callback, { once = true })
end

function M.off(name, callback)
	for _, item in ipairs(listeners) do
		if item.name == name and item.callback == callback then
			item.active = false
		end
	end
end

local function report(name, err)
	vim.schedule(function()
		vim.notify("aero: " .. name .. " handler failed: " .. tostring(err), vim.log.levels.ERROR)
	end)
end

function M.emit(name, data)
	valid(name)
	assert(name ~= "*", "aero: cannot emit the wildcard event")
	local payload = vim.tbl_extend("force", data or {}, { event = name })
	if vim.in_fast_event() then
		local copy = vim.deepcopy(payload)
		vim.schedule(function()
			M.emit(name, copy)
		end)
		return
	end
	-- Snapshot registration order: new listeners start with the next emission.
	local snapshot = vim.list_slice(listeners)
	for _, item in ipairs(snapshot) do
		if item.active and (item.name == name or item.name == "*") then
			if item.once then
				item.active = false
			end
			local ok, err = xpcall(function()
				item.callback(vim.deepcopy(payload))
			end, debug.traceback)
			if not ok then
				report(name, err)
			end
		end
	end
	listeners = vim.tbl_filter(function(item)
		return item.active
	end, listeners)
	local pattern = "Aero" .. name:gsub("^%l", string.upper):gsub("_(%l)", string.upper)
	local ok, err =
		pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = vim.deepcopy(payload), modeline = false })
	if not ok then
		report(name, err)
	end
end

--- Replace setup()-configured handlers while preserving programmatic subscriptions.
function M.setup(handlers)
	for _, unsubscribe in ipairs(configured) do
		unsubscribe()
	end
	configured = {}
	for name, callbacks in pairs(handlers or {}) do
		if type(callbacks) == "function" then
			callbacks = { callbacks }
		end
		assert(type(callbacks) == "table", "aero: events entries must be a function or a list of functions")
		for _, callback in ipairs(callbacks) do
			table.insert(configured, M.on(name, callback))
		end
	end
end

--- Stable session metadata without process handles or protocol callbacks.
function M.session(s, extra)
	return vim.tbl_extend("force", {
		key = s.key,
		name = s.name,
		agent = s.agent,
		worktree = s.worktree,
		buf = s.buf,
	}, extra or {})
end

return M
