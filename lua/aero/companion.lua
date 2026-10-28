-- Private scoped companion protocol: no eval, editor commands, or Neovim RPC.
local M = {}
local uv = vim.uv
local server, directory, endpoint, settings_path
local process, leaving
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))
local stop_clients
local identities = setmetatable({}, { __mode = "k" })
local permissions = setmetatable({}, { __mode = "k" })
local conversation_ids = setmetatable({}, { __mode = "k" })
local receipts = require("aero.companion.receipts").new()
local worktree_cache, worktree_cache_at, worktree_roots = {}, -5000, ""
local epoch = (assert(uv.random(24)):gsub(".", function(c)
	return ("%02x"):format(c:byte())
end))
local lifecycle = {
	session_create = true,
	session_resume = true,
	session_rename = true,
	session_delete = true,
	worktree_create = true,
	worktree_rename = true,
	worktree_delete = true,
}

local function worktrees()
	local workspaces = require("aero.store").data.workspaces
	local roots = vim.json.encode(workspaces)

	if roots ~= worktree_roots or uv.now() - worktree_cache_at >= 5000 then
		worktree_cache, worktree_cache_at, worktree_roots = {}, uv.now(), roots

		for _, workspace in ipairs(workspaces) do
			worktree_cache[workspace.root] = require("aero.git").list(workspace.root) or {}
		end
	end

	local list = {}

	for _, repository in
		ipairs(require("aero.repositories").list(function(ws)
			return worktree_cache[ws.root]
		end))
	do
		for _, tree in ipairs(repository.list) do
			local wt = vim.deepcopy(tree)
			wt.workspace = repository.ws.root
			list[wt.path] = wt
		end
	end

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

local function describe(s, boards)
	return require("aero.companion.snapshot").describe(s, boards, identity, identities, permissions, conversation_ids)
end

function M.dispatch(method, params)
	params = params or {}
	local sessions = require("aero.session").all()

	if method == "snapshot" then
		return require("aero.companion.snapshot").build(epoch, worktrees(), sessions, describe, function(chat)
			return identity(chat, identities)
		end)
	end

	if method == "reference_browse" then
		for _, tree in ipairs(worktrees()) do
			if
				tree.path == params.worktree
				and params.epoch == epoch
				and params.target == require("aero.companion_lifecycle").target(epoch, tree)
			then
				return require("aero.companion.reference").browse(params)
			end
		end

		return nil, "stale worktree or host epoch"
	end

	if method == "prompt_snippets" then
		if params.epoch ~= epoch then
			return nil, "stale host epoch"
		end

		for _, s in ipairs(sessions) do
			if s.key == params.session and s.chat then
				describe(s)

				if identity(s.chat, identities) ~= params.conversation then
					return nil, "stale conversation"
				end

				local snippets = require("aero.prompt_snippets")
				local items, errors = snippets.list(s.worktree)
				local templates = {}

				for _, item in ipairs(items) do
					table.insert(templates, item.prompt)
				end

				return {
					items = items,
					errors = errors,
					context = snippets.context(s.chat, table.concat(templates, "\n")),
				}
			end
		end

		return nil, "session unavailable"
	end

	if
		not lifecycle[method]
		and method ~= "session_assign_board"
		and method ~= "prompt"
		and method ~= "cancel"
		and method ~= "permission"
		and method ~= "reference_update"
		and method ~= "reference_cancel"
	then
		return nil, "unknown method"
	end

	local fingerprint, receipt_err, previous = receipts.check(method, params)

	if not fingerprint then
		return nil, receipt_err
	end

	if previous then
		return previous.result, previous.error
	end

	local function finish(result, err)
		receipts.finish(params.operation_id, fingerprint, result, err)

		if lifecycle[method] then
			worktree_cache_at = -5000
		end

		if method:match("^worktree_") and result and result.status == "accepted" then
			require("aero.submodules").invalidate(true)
		end

		return result, err
	end

	if method == "reference_update" or method == "reference_cancel" then
		for _, tree in ipairs(worktrees()) do
			if
				tree.path == params.worktree
				and params.epoch == epoch
				and params.target == require("aero.companion_lifecycle").target(epoch, tree)
			then
				finish({ status = "unknown" })

				if method == "reference_cancel" then
					return finish(
						require("aero.companion.reference_transfer").cancel(params.worktree, params.transfer_id)
					)
				end

				local ok, result, err = pcall(require("aero.companion.reference").update, params, finish)

				if not ok then
					return finish(nil, tostring(result))
				end

				return finish(result, err)
			end
		end

		return finish(nil, "stale worktree or host epoch")
	end

	local selected

	for _, s in ipairs(sessions) do
		if s.key == params.session then
			selected = s
		end
	end

	local chat = selected and selected.chat

	if method == "session_assign_board" then
		if params.epoch ~= epoch or not selected or params.target ~= identity(selected, identities) then
			return finish(nil, "stale session or host epoch")
		end

		if type(params.board_id) ~= "string" or params.board_id == "" or type(params.replace) ~= "boolean" then
			return finish(nil, "board_id and replacement choice required")
		end

		local workspace = require("aero.repositories").find(params.workspace)

		if not workspace then
			return finish(nil, "workspace unavailable")
		end

		if not chat or params.conversation ~= describe(selected).conversation then
			return finish(nil, "stale conversation")
		end

		finish({ status = "unknown" })
		require("aero.tasks.assignment").assign_board(
			selected,
			workspace,
			params.board_id,
			params.replace,
			function(ok, err)
				finish(
					ok and { status = "accepted" } or nil,
					err and (type(err) == "table" and err.message or tostring(err)) or nil
				)
			end
		)
		local receipt = receipts.get(params.operation_id)
		return receipt.result, receipt.error
	end

	if lifecycle[method] then
		if params.epoch ~= epoch then
			return finish(nil, "stale host epoch")
		end

		if method ~= "session_create" and method:match("^session_") then
			if not selected or params.target ~= identity(selected, identities) then
				return finish(nil, "stale session")
			end
		end

		finish({ status = "unknown" })
		require("aero.companion_lifecycle").run(method, params, sessions, finish)
		worktree_cache_at = -5000
		local receipt = receipts.get(params.operation_id)
		return receipt.result, receipt.error
	end

	if not chat then
		return finish(nil, "session unavailable")
	end

	describe(selected) -- Rotate the generation if the ACP conversation changed in place.

	if identity(chat, identities) ~= params.conversation then
		return finish(nil, "stale conversation")
	end

	if method == "prompt" and type(params.text) == "string" and vim.trim(params.text):match("^/export") then
		local command = vim.trim(params.text)

		if command == "/export" or command == "/export readable" then
			finish({ status = "unknown" })
			local path = require("aero.exports").export(chat, { readable = command == "/export readable" })

			if not path then
				return finish(nil, "could not export log")
			end

			return finish({ status = "accepted", message = "Exported log: " .. path })
		end
	end

	if chat.state == "exited" or not chat.client then
		return finish(nil, "agent unavailable")
	end

	if method == "prompt" then
		if type(params.text) ~= "string" or vim.trim(params.text) == "" or #params.text > 65536 then
			return finish(nil, "prompt must contain 1-65536 bytes")
		end

		local text = params.text
		local control = false

		if vim.trim(text):match("^/") then
			local command, rest = vim.trim(text):match("^([^\n]+)\n?(.*)$")
			local name, argument = vim.trim(text):match("^/(%S+)%s*(.*)$")

			if name == "context" then -- preserve drafts created before the feature rename
				name = "reference"
				command = command:gsub("^/context", "/reference")
			end

			if name == "cancel" then
				if argument ~= "" then
					return finish(nil, "use /cancel without arguments")
				end

				finish({ status = "unknown" })
				chat:cancel()
				return finish({ status = "accepted" })
			elseif name == "model" or name == "mode" then
				local selector = require("aero.acp." .. name .. "s")

				if argument == "" or text:find("[\r\n]") then
					return finish(nil, "choose an available " .. name .. " in the companion")
				end

				local choice = selector.resolve(chat, argument)

				if not choice then
					return finish(nil, "unknown or ambiguous " .. name .. ": " .. argument)
				end

				text, control = "/" .. name .. " " .. choice.id, true
			elseif name == "new-ticket" then
				local expanded, err = require("aero.tasks.agent").expand_new_ticket(selected, text)

				if not expanded then
					return finish(nil, "Assign a board in the companion before using /new-ticket. " .. err)
				end

				text = expanded
			elseif name == "export" then
				return finish(nil, "use /export or /export readable")
			elseif name == "prompt" then
				return finish(nil, "choose a prompt snippet in the companion before sending")
			elseif name ~= "report" and name ~= "reference" then
				local advertised = false

				for _, available in ipairs(chat.commands or {}) do
					if available.name == name then
						advertised = true
						break
					end
				end

				if not advertised then
					return finish(nil, "unknown slash command: /" .. name)
				end

				control = true
			end

			if name == "reference" then
				local relative = command:match("^/reference%s+select%s+(.+)$")
				local entry, err = require("aero.companion.reference").entry(selected.worktree, relative)

				if not entry then
					return finish(nil, err or "use /reference select <path>")
				end

				text = "Read this reference "
					.. (entry.kind == "directory" and "folder" or "file")
					.. ": "
					.. vim.json.encode(entry.path)

				if rest ~= "" then
					text = text .. "\n\n" .. rest
				end
			elseif name == "report" then
				local action, name = command:match("^/report%s+(%S+)%s+(.+)$")

				if action ~= "new" and action ~= "select" then
					return finish(nil, "use /report new <name> or /report select <filename>")
				end

				local reports = require("aero.reports")
				local ws

				for _, tree in ipairs(worktrees()) do
					if tree.path == selected.worktree then
						ws = { root = tree.workspace }
						break
					end
				end

				local report, err

				if action == "new" then
					report, err = reports.create_file(selected.worktree, ws, name, "")
				else
					local choices
					choices, err = reports.list(selected.worktree, ws)

					for _, choice in ipairs(choices) do
						if choice.name == name then
							report = choice
							break
						end
					end
				end

				if not report then
					return finish(nil, err or "report unavailable")
				end

				text = require("aero.config").options.reports.prompt:gsub("{path}", function()
					return vim.json.encode(report.path)
				end)

				if rest ~= "" then
					text = text .. "\n\n" .. rest
				end
			end
		end

		local queued = chat.state ~= "ready"
			or chat.busy
			or chat.model_pending
			or chat.mode_pending
			or chat.task_pending
		finish({ status = "unknown" })
		local binding = selected.task_binding

		if binding and not binding.revoked and not control then
			text = table.concat({
				"Current Aero assignment: workspace "
					.. vim.json.encode(binding.workspace.root)
					.. ", board "
					.. vim.json.encode(binding.board_id)
					.. ".",
				binding.ticket_id and ("Assigned ticket: " .. vim.json.encode(binding.ticket_id) .. ".")
					or "Board-only assignment: no ticket is assigned. Read the board and create tickets through Aero MCP tools when requested; do not implement them unless asked.",
				"Use the current assignment rather than any superseded assignment in this conversation. Do not write task documents directly.",
				"",
				text,
			}, "\n")
		end

		chat:prompt(text)
		finish({ status = queued and "queued" or "accepted" })
	elseif method == "cancel" then
		finish({ status = "unknown" })
		chat:cancel()
		finish({ status = "accepted" })
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
		finish({ status = "accepted" })
	end

	return receipts.get(params.operation_id).result
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

	if stop_clients then
		stop_clients()
		stop_clients = nil
	end

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
	stop_clients = require("aero.companion.transport").listen(server, M.dispatch)
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
