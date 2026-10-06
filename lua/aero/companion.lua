-- Private scoped companion protocol: no eval, editor commands, or Neovim RPC.
local M = {}
local uv = vim.uv
local server, directory, endpoint, settings_path
local process, leaving
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local clients = {}
local identities = setmetatable({}, { __mode = "k" })
local permissions = setmetatable({}, { __mode = "k" })
local conversation_ids = setmetatable({}, { __mode = "k" })
local operations, operation_count = {}, 0
local worktree_cache, worktree_cache_at, worktree_roots = {}, -5000, ""

local function worktrees()
	local workspaces = require("aero.store").data.workspaces
	local roots = vim.json.encode(workspaces)
	if roots ~= worktree_roots or uv.now() - worktree_cache_at >= 5000 then
		worktree_cache, worktree_cache_at, worktree_roots = {}, uv.now(), roots
		for _, workspace in ipairs(workspaces) do
			for _, wt in ipairs(require("aero.git").list(workspace.root) or {}) do
				wt.workspace = workspace.root
				worktree_cache[wt.path] = wt
			end
		end
	end
	local list = vim.deepcopy(worktree_cache)
	for path in pairs(require("aero.store").data.sessions) do
		list[path] = list[path] or { path = path }
	end
	local result = vim.tbl_values(list)
	table.sort(result, function(a, b)
		return a.path < b.path
	end)
	return result
end

local function identity(object, registry)
	if not registry[object] then
		registry[object] = (assert(uv.random(24)):gsub(".", function(c)
			return ("%02x"):format(c:byte())
		end))
	end
	return registry[object]
end

local function describe(s)
	local chat = s.chat
	local result = {
		id = s.key,
		name = s.name,
		agent = s.agent,
		worktree = s.worktree,
		status = require("aero.session").status(s),
	}
	if chat then
		if conversation_ids[chat] ~= (chat.session_id or chat.saved_session_id or false) then
			identities[chat] = nil
			conversation_ids[chat] = chat.session_id or chat.saved_session_id or false
		end
		result.conversation = identity(chat, identities)
		result.acp_session_id = chat.session_id or chat.saved_session_id
		result.blocks = vim.deepcopy(chat.blocks)
		for _, b in ipairs(result.blocks) do
			b.cache, b.cache_src, b.shown = nil, nil, nil
		end
		result.queue = vim.deepcopy(chat.queue)
		if chat.permission then
			result.permission = {
				id = identity(chat.permission, permissions),
				title = chat.permission.block.title,
				options = chat.permission.block.options,
			}
		end
	end
	return result
end

function M.dispatch(method, params)
	params = params or {}
	local sessions = require("aero.session").all()
	if method == "snapshot" then
		local result =
			{ workspaces = require("aero.store").data.workspaces, worktrees = worktrees(), sessions = {}, inbox = {} }
		for _, s in ipairs(sessions) do
			local agent = require("aero.config").options.agents[s.agent]
			if s.chat or agent and agent.type == "acp" then
				table.insert(result.sessions, describe(s))
			end
		end
		for _, e in ipairs(require("aero.inbox").items()) do
			table.insert(result.inbox, {
				id = e.key,
				session = e.session.key,
				conversation = identity(e.chat, identities),
				kind = e.kind,
				text = e.text,
				workspace = e.workspace,
				ticket = e.ticket,
			})
		end
		return result
	end
	if method ~= "prompt" and method ~= "cancel" and method ~= "permission" then
		return nil, "unknown method"
	end
	if type(params.operation_id) ~= "string" or #params.operation_id < 16 or #params.operation_id > 128 then
		return nil, "operation_id required (16-128 characters)"
	end
	local fingerprint = vim.json.encode({
		method,
		params.session,
		params.conversation,
		params.text or false,
		params.permission or false,
		params.option or false,
	})
	local previous = operations[params.operation_id]
	if previous then
		if previous.fingerprint ~= fingerprint then
			return nil, "operation_id reused with different arguments"
		end
		return previous.result, previous.error
	end
	-- Refuse new operations rather than evicting receipts and risking duplicate retries.
	if operation_count >= 10000 then
		return nil, "operation receipt capacity reached"
	end
	local function finish(result, err)
		operations[params.operation_id] = { fingerprint = fingerprint, result = result, error = err }
		operation_count = operation_count + 1
		return result, err
	end
	local selected
	for _, s in ipairs(sessions) do
		if s.key == params.session then
			selected = s
		end
	end
	local chat = selected and selected.chat
	if not chat then
		return finish(nil, "session unavailable")
	end
	describe(selected) -- Rotate the generation if the ACP conversation changed in place.
	if identity(chat, identities) ~= params.conversation then
		return finish(nil, "stale conversation")
	end
	if chat.state == "exited" or not chat.client then
		return finish(nil, "agent unavailable")
	end
	if method == "prompt" then
		if type(params.text) ~= "string" or vim.trim(params.text) == "" or #params.text > 65536 then
			return finish(nil, "prompt must contain 1-65536 bytes")
		end
		-- Editor-local slash commands may open pickers or change task bindings.
		if vim.trim(params.text):match("^/") then
			return finish(nil, "remote slash commands are unsupported")
		end
		local queued = chat.state ~= "ready"
			or chat.busy
			or chat.model_pending
			or chat.mode_pending
			or chat.task_pending
		finish({ status = "unknown" })
		chat:prompt(params.text)
		operations[params.operation_id].result = { status = queued and "queued" or "accepted" }
	elseif method == "cancel" then
		finish({ status = "unknown" })
		chat:cancel()
		operations[params.operation_id].result = { status = "accepted" }
	else
		local p = chat.permission
		if not p or identity(p, permissions) ~= params.permission then
			return finish(nil, "stale permission")
		end
		local index
		for i, option in ipairs(p.block.options) do
			if option.optionId == params.option then
				index = i
			end
		end
		if not index then
			return finish(nil, "invalid permission choice")
		end
		finish({ status = "unknown" })
		chat:choose(index)
		operations[params.operation_id].result = { status = "accepted" }
	end
	return operations[params.operation_id].result
end

function M.stop()
	if process and not process.stopping then
		process.stopping = true
		if process.id and process.id > 0 then
			pcall(vim.fn.chansend, process.id, vim.json.encode({ method = "stop" }) .. "\n")
			pcall(vim.fn.jobstop, process.id)
		end
	end
	require("aero.companion_ui").close()
	for client in pairs(clients) do
		if not client:is_closing() then
			client:close()
		end
	end
	clients = {}
	if server and not server:is_closing() then
		server:close()
	end
	server = nil
	if endpoint then
		uv.fs_unlink(endpoint)
	end
	if settings_path then
		uv.fs_unlink(settings_path)
	end
	if directory then
		uv.fs_rmdir(directory)
	end
	endpoint, directory, settings_path = nil, nil, nil
end

function M.start()
	if server then
		return endpoint, settings_path
	end
	directory = vim.fn.tempname()
	assert(uv.fs_mkdir(directory, 448))
	endpoint = directory .. "/companion.sock"
	server = uv.new_pipe(false)
	assert(server:bind(endpoint))
	assert(uv.fs_chmod(endpoint, 384))
	-- Export setup options to the separate Go process, without exposing them over HTTP.
	local options = require("aero.config").options.companion
	assert(type(options.allow_http) == "boolean", "companion.allow_http must be a boolean")
	local settings = {
		socket = endpoint,
		bind = options.bind,
		port = options.port,
		origin = options.origin,
		allow_http = options.allow_http,
		cert = options.cert or nil,
		key = options.key or nil,
		devices_file = options.devices_file and vim.fn.expand(options.devices_file)
			or vim.fn.stdpath("data")
				.. "/Aero/companion/devices-"
				.. vim.fn.sha256(options.origin):sub(1, 16)
				.. ".json",
	}
	for _, field in ipairs({ "cert", "key" }) do
		if settings[field] then
			settings[field] = vim.fn.expand(settings[field])
		end
	end
	settings_path = directory .. "/companion.json"
	local encoded = vim.json.encode(settings)
	local fd = assert(uv.fs_open(settings_path, "w", 384))
	local written, write_error = uv.fs_write(fd, encoded, 0)
	uv.fs_close(fd)
	assert(written, write_error)
	server:listen(16, function(err)
		if err then
			return
		end
		local client, buffer, pending = uv.new_pipe(false), "", false
		server:accept(client)
		clients[client] = true
		local function close()
			clients[client] = nil
			if not client:is_closing() then
				client:close()
			end
		end
		client:read_start(function(read_err, chunk)
			if read_err or not chunk then
				close()
				return
			end
			buffer = buffer .. chunk
			if #buffer > 131072 or pending then
				close()
				return
			end
			if not buffer:find("\n", 1, true) then
				return
			end
			pending = true
			vim.schedule(function()
				local ok, request = pcall(vim.json.decode, buffer)
				local result, failure
				if ok and type(request) == "table" then
					local success
					success, result, failure = pcall(M.dispatch, request.method, request.params)
					if not success then
						result, failure = nil, "host action failed; outcome unknown"
					end
				else
					failure = "invalid request"
				end
				if not client:is_closing() then
					client:write(vim.json.encode({ result = result, error = failure }) .. "\n", close)
				end
			end)
		end)
	end)
	vim.api.nvim_create_autocmd("VimLeavePre", {
		once = true,
		callback = function()
			leaving = true
			M.stop()
		end,
	})
	return endpoint, settings_path
end

local function control(method, device)
	if not process or process.stopping or not process.ready then
		return false
	end
	return pcall(vim.fn.chansend, process.id, vim.json.encode({ method = method, device = device }) .. "\n")
end

local function actions(owner)
	return {
		pair = function()
			M.command("pair")
		end,
		revoke = function()
			M.command("revoke")
		end,
		stop = function()
			M.command("stop")
		end,
		closed = function()
			if process == owner then
				owner.show = false
			end
		end,
	}
end

function M.status()
	local pid
	if process and process.id and process.id > 0 then
		local ok, value = pcall(vim.fn.jobpid, process.id)
		if ok and value > 0 then
			pid = value
		end
	end
	return {
		running = pid ~= nil and not process.stopping,
		ready = process and process.ready and not process.stopping or false,
		pid = pid,
		info = process and process.info or nil,
	}
end

local function executable()
	local configured = require("aero.config").options.companion.executable
	if configured then
		local path = vim.fn.expand(configured)
		assert(vim.fn.executable(path) == 1, "companion.executable is not executable")
		return path
	end
	local path = plugin_root .. "/apps/companion/aero-companion"
	if vim.fn.executable(path) == 1 then
		return path
	end
	local installed, install_err = require("aero.companion_install").resolve()
	if installed then
		return installed
	end
	path = vim.fn.exepath("aero-companion")
	assert(path ~= "", install_err or "Companion executable not found. Run :Aero companion install")
	return path
end

local function receive(owner, data)
	if process ~= owner or owner.stopping then
		return
	end
	owner.buffer = owner.buffer .. table.concat(data, "\n")
	if #owner.buffer > 65536 then
		owner.failed = true
		M.stop()
		vim.notify("Aero: invalid companion control response", vim.log.levels.ERROR)
		return
	end
	while owner.buffer:find("\n", 1, true) do
		local at = owner.buffer:find("\n", 1, true)
		local line = owner.buffer:sub(1, at - 1)
		owner.buffer = owner.buffer:sub(at + 1)
		if line ~= "" then
			local ok, event = pcall(vim.json.decode, line)
			if not ok or type(event) ~= "table" or not event.event then
				owner.failed = true
				M.stop()
				vim.notify(
					"Aero: companion protocol unavailable; rebuild with make build-companion",
					vim.log.levels.ERROR
				)
				return
			end
			if event.event == "error" then
				vim.notify("Aero companion: " .. tostring(event.message or "operation failed"), vim.log.levels.ERROR)
				if not owner.ready then
					owner.failed = true
					M.stop()
				end
			elseif not owner.info or (event.revision or 0) >= (owner.info.revision or 0) then
				-- Concurrent phone/local controls can finish out of order; only show newer state.
				if event.event == "ready" then
					owner.ready = true
				end
				owner.info = event
				if owner.revoke and owner.ready then
					owner.revoke = false
					require("aero.companion_ui").revoke(event.devices or {}, function(id)
						control("revoke", id)
					end)
				end
				require("aero.companion_ui").show(event, actions(owner), owner.show == true)
				owner.show = false
			end
		end
	end
end

function M.launch()
	if leaving then
		return
	end
	if process then
		if process.stopping then
			process.restart = true
			return
		end
		process.show = true
		if process.ready then
			if not process.info.code or (process.info.expires_at or 0) <= os.time() then
				control("pair")
			else
				require("aero.companion_ui").show(process.info, actions(process), true)
				process.show = false
			end
		end
		return
	end
	local path = executable()
	local _, settings = M.start()
	local owner = { ready = false, show = true, buffer = "" }
	process = owner
	require("aero.companion_ui").show(
		{ starting = true, origin = require("aero.config").options.companion.origin },
		actions(owner),
		true
	)
	owner.id = vim.fn.jobstart({ path, "--config", settings, "--stdio-control" }, {
		on_stdout = function(_, data)
			receive(owner, data)
		end,
		on_stderr = function() end, -- No process output or pairing credentials are written to logs.
		on_exit = function(_, code)
			if process ~= owner then
				return
			end
			process = nil
			M.stop()
			if not owner.stopping and not owner.failed and not leaving then
				vim.notify(
					"Aero: companion exited (" .. code .. "); use :Aero companion start to restart",
					vim.log.levels.WARN
				)
			end
			if owner.restart and not leaving then
				vim.schedule(function()
					M.command("start")
				end)
			end
		end,
	})
	if owner.id <= 0 then
		process = nil
		M.stop()
		error("could not launch companion executable")
	end
	vim.defer_fn(function()
		if process == owner and not owner.ready and not owner.stopping then
			owner.failed = true
			M.stop()
			vim.notify("Aero: companion startup timed out", vim.log.levels.ERROR)
		end
	end, 10000)
end

function M.command(action)
	if action == "install" then
		return require("aero.companion_install").install()
	end
	if action == "stop" then
		M.stop()
		vim.notify("Aero: companion stopped; remembered devices are kept")
		return
	end
	if action and not vim.tbl_contains({ "start", "pair", "devices", "revoke" }, action) then
		vim.notify("Aero: use :Aero companion [install|start|stop|pair|devices|revoke]", vim.log.levels.WARN)
		return
	end
	local ok, err = pcall(function()
		if process and process.ready and not process.stopping and action and action ~= "start" then
			process.show = true
			if action == "revoke" then
				process.revoke = true
			end
			control(action == "pair" and "pair" or "devices")
		else
			M.launch()
			if process and action == "revoke" then
				process.revoke = true
			end
		end
	end)
	if not ok then
		M.stop()
		vim.notify("Aero: companion failed: " .. tostring(err), vim.log.levels.ERROR)
		return
	end
end

return M
