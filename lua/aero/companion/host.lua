-- Local socket and managed companion process lifetime, independent of capability dispatch.
local M = {}
local uv = vim.uv
local server, directory, endpoint, settings_path
local process, leaving, stop_clients
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))))

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
	local fd = assert(uv.fs_open(settings_path, "w", 384))
	local written, err = uv.fs_write(fd, vim.json.encode(settings), 0)
	uv.fs_close(fd)
	assert(written, err)
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

	local installed, err = require("aero.companion_install").resolve()

	if installed then
		return installed
	end

	path = vim.fn.exepath("aero-companion")
	assert(path ~= "", err or "Companion executable not found. Run :Aero companion install")
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
		on_stderr = function() end,
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
	end
end

return M
