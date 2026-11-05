-- Experimental Pixel embed host. Chromium owns the image; Neovim owns its
-- Unicode-placeholder placement, so ordinary buffer visibility clips the image.
local api, uv = vim.api, vim.uv
local M = {}
local instances = {}
local serial = 0
local initialized = false
local opening = {}
local failures = {}
-- Exact Kitty protocol indices, not a general list of combining characters:
-- https://sw.kovidgoyal.net/kitty/_downloads/f0a0de9ec8d9ff4456206db8e0814937/rowcolumn-diacritics.txt
local diacritics = {
	0x0305,
	0x030d,
	0x030e,
	0x0310,
	0x0312,
	0x033d,
	0x033e,
	0x033f,
	0x0346,
	0x034a,
	0x034b,
	0x034c,
	0x0350,
	0x0351,
	0x0352,
	0x0357,
	0x035b,
	0x0363,
	0x0364,
	0x0365,
	0x0366,
	0x0367,
	0x0368,
	0x0369,
	0x036a,
	0x036b,
	0x036c,
	0x036d,
	0x036e,
	0x036f,
	0x0483,
	0x0484,
	0x0485,
	0x0486,
	0x0487,
	0x0592,
	0x0593,
	0x0594,
	0x0595,
	0x0597,
	0x0598,
	0x0599,
	0x059c,
	0x059d,
	0x059e,
	0x059f,
	0x05a0,
	0x05a1,
	0x05a8,
	0x05a9,
	0x05ab,
	0x05ac,
	0x05af,
	0x05c4,
	0x0610,
	0x0611,
	0x0612,
	0x0613,
	0x0614,
	0x0615,
	0x0616,
	0x0617,
	0x0657,
	0x0658,
	0x0659,
	0x065a,
	0x065b,
	0x065d,
	0x065e,
	0x06d6,
	0x06d7,
	0x06d8,
	0x06d9,
	0x06da,
	0x06db,
	0x06dc,
	0x06df,
	0x06e0,
	0x06e1,
	0x06e2,
	0x06e4,
	0x06e7,
	0x06e8,
	0x06eb,
	0x06ec,
	0x0730,
	0x0732,
	0x0733,
	0x0735,
	0x0736,
	0x073a,
	0x073d,
	0x073f,
	0x0740,
	0x0741,
	0x0743,
	0x0745,
	0x0747,
	0x0749,
	0x074a,
	0x07eb,
	0x07ec,
	0x07ed,
	0x07ee,
	0x07ef,
	0x07f0,
	0x07f1,
	0x07f3,
	0x0816,
	0x0817,
	0x0818,
	0x0819,
	0x081b,
	0x081c,
	0x081d,
	0x081e,
	0x081f,
	0x0820,
	0x0821,
	0x0822,
	0x0823,
	0x0825,
	0x0826,
	0x0827,
	0x0829,
	0x082a,
	0x082b,
	0x082c,
	0x082d,
	0x0951,
	0x0953,
	0x0954,
	0x0f82,
	0x0f83,
	0x0f86,
	0x0f87,
	0x135d,
	0x135e,
	0x135f,
	0x17dd,
	0x193a,
	0x1a17,
	0x1a75,
	0x1a76,
	0x1a77,
	0x1a78,
	0x1a79,
	0x1a7a,
	0x1a7b,
	0x1a7c,
	0x1b6b,
	0x1b6d,
	0x1b6e,
	0x1b6f,
	0x1b70,
	0x1b71,
	0x1b72,
	0x1b73,
	0x1cd0,
	0x1cd1,
	0x1cd2,
	0x1cda,
	0x1cdb,
	0x1ce0,
	0x1dc0,
	0x1dc1,
	0x1dc3,
	0x1dc4,
	0x1dc5,
	0x1dc6,
	0x1dc7,
	0x1dc8,
	0x1dc9,
	0x1dcb,
	0x1dcc,
	0x1dd1,
	0x1dd2,
	0x1dd3,
	0x1dd4,
	0x1dd5,
	0x1dd6,
	0x1dd7,
	0x1dd8,
	0x1dd9,
	0x1dda,
	0x1ddb,
	0x1ddc,
	0x1ddd,
	0x1dde,
	0x1ddf,
	0x1de0,
	0x1de1,
	0x1de2,
	0x1de3,
	0x1de4,
	0x1de5,
	0x1de6,
	0x1dfe,
	0x20d0,
	0x20d1,
	0x20d4,
	0x20d5,
	0x20d6,
	0x20d7,
	0x20db,
	0x20dc,
	0x20e1,
	0x20e7,
	0x20e9,
	0x20f0,
	0x2cef,
	0x2cf0,
	0x2cf1,
	0x2de0,
	0x2de1,
	0x2de2,
	0x2de3,
	0x2de4,
	0x2de5,
	0x2de6,
	0x2de7,
	0x2de8,
	0x2de9,
	0x2dea,
	0x2deb,
	0x2dec,
	0x2ded,
	0x2dee,
	0x2def,
	0x2df0,
	0x2df1,
	0x2df2,
	0x2df3,
	0x2df4,
	0x2df5,
	0x2df6,
	0x2df7,
	0x2df8,
	0x2df9,
	0x2dfa,
	0x2dfb,
	0x2dfc,
	0x2dfd,
	0x2dfe,
	0x2dff,
	0xa66f,
	0xa67c,
	0xa67d,
	0xa6f0,
	0xa6f1,
	0xa8e0,
	0xa8e1,
	0xa8e2,
	0xa8e3,
	0xa8e4,
	0xa8e5,
	0xa8e6,
	0xa8e7,
	0xa8e8,
	0xa8e9,
	0xa8ea,
	0xa8eb,
	0xa8ec,
	0xa8ed,
	0xa8ee,
	0xa8ef,
	0xa8f0,
	0xa8f1,
	0xaab0,
	0xaab2,
	0xaab3,
	0xaab7,
	0xaab8,
	0xaabe,
	0xaabf,
	0xaac1,
	0xfe20,
	0xfe21,
	0xfe22,
	0xfe23,
	0xfe24,
	0xfe25,
	0xfe26,
	0x10a0f,
	0x10a38,
	0x1d185,
	0x1d186,
	0x1d187,
	0x1d188,
	0x1d189,
	0x1d1aa,
	0x1d1ab,
	0x1d1ac,
	0x1d1ad,
	0x1d242,
	0x1d243,
	0x1d244,
}

local function notify(message)
	vim.notify("Aero browser: " .. message, vim.log.levels.WARN)
end

local function send(s, message)
	if s.connection and not s.connection:is_closing() then
		s.connection:write(vim.json.encode(message) .. "\n")
	end
end

local function visible_window(s)
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if api.nvim_win_get_buf(win) == s.buf then
			return win
		end
	end
end

local function size(s, win, kind)
	local cols, rows =
		math.min(api.nvim_win_get_width(win), #diacritics), math.min(api.nvim_win_get_height(win), #diacritics)
	return {
		type = kind or "size",
		cols = cols,
		rows = rows,
		width = cols * s.cell[1],
		height = rows * s.cell[2],
		cell = s.cell,
	}
end

local function draw(s, message)
	if not api.nvim_buf_is_valid(s.buf) then
		return
	end

	local id = message.imageId
	local output = {
		"\027[2J\027[3J\027[H",
		string.format(
			"\027[38;2;%d;%d;%dm",
			bit.band(bit.rshift(id, 16), 255),
			bit.band(bit.rshift(id, 8), 255),
			bit.band(id, 255)
		),
	}

	for row = 1, math.min(message.rows, #diacritics) do
		output[#output + 1] = string.format("\027[%d;1H", row)

		for col = 1, math.min(message.cols, #diacritics) do
			output[#output + 1] = vim.fn.nr2char(0x10eeee)
				.. vim.fn.nr2char(diacritics[row])
				.. vim.fn.nr2char(diacritics[col])
		end
	end

	output[#output + 1] = "\027[0m\027[H"
	api.nvim_chan_send(s.channel, table.concat(output))
end

local function close_handle(handle)
	if handle and not handle:is_closing() then
		handle:close()
	end
end

local function stop(s)
	if s.stopped then
		return
	end

	s.stopped = true
	instances[s.worktree] = nil

	if s.frames then
		s.frames.stop()
	end

	close_handle(s.connection)
	close_handle(s.server)
	uv.fs_unlink(s.socket)

	if s.job and s.job > 0 then
		vim.fn.jobstop(s.job)
	end

	if api.nvim_buf_is_valid(s.buf) then
		api.nvim_chan_send(s.channel, "\027[2J\027[HBrowser stopped. Reopen with :Aero reader browser\r\n")
	end
end

local function refresh()
	for _, s in pairs(instances) do
		local win = visible_window(s)
		send(s, { type = "visible", value = win ~= nil })
		send(s, { type = "focus", focused = win == api.nvim_get_current_win() })

		if win then
			if require("aero.config").options.browser.auto_cell_size then
				local cell = require("aero.browser.terminal").cell(s.tty)

				if cell then
					s.cell[1], s.cell[2] = cell[1], cell[2]
				end
			end

			local message = size(s, win)
			local signature = table.concat({ message.cols, message.rows, s.cell[1], s.cell[2] }, ":")

			if signature ~= s.size then
				s.size = signature

				if s.frames then
					s.frames.resize(message)
					api.nvim_chan_send(s.channel, "\027[2J\027[3J\027[H")
				end

				send(s, message)
			end
		end
	end
end

local function setup()
	if initialized then
		return
	end

	initialized = true
	local group = api.nvim_create_augroup("Aero.browser", { clear = true })
	api.nvim_create_autocmd({ "WinResized", "BufWinEnter", "BufWinLeave", "TabEnter", "WinEnter", "WinClosed" }, {
		group = group,
		callback = function()
			vim.schedule(refresh)
		end,
	})
	api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			for _, s in pairs(vim.tbl_values(instances)) do
				stop(s)
			end
		end,
	})
end

local function tty_path()
	local pane = vim.env.TMUX_PANE
	local local_ui = false

	for _, ui in ipairs(api.nvim_list_uis()) do
		local_ui = local_ui or (ui.stdin_tty == true and ui.stdout_tty == true)
	end

	if local_ui and pane and pane ~= "" then
		-- Embedded terminal-browser writes unwrapped Kitty graphics. Send those
		-- directly to the enclosing client, not the pane where tmux consumes them.
		local ok, resolved = pcall(function()
			return vim.system(
				{ "tmux", "display-message", "-p", "-t", pane, "#{client_tty}" },
				{ text = true, timeout = 3000 }
			)
				:wait()
		end)

		if ok and resolved.code == 0 then
			local tty = vim.trim(resolved.stdout or "")

			if tty:match("^/dev/%S+$") then
				return tty
			end
		end

		return nil
	end

	local result = vim.system({ "ps", "-p", tostring(vim.fn.getpid()), "-o", "tty=" }, { text = true }):wait()
	local tty = vim.trim(result.stdout or "")

	if result.code == 0 and tty ~= "" and tty ~= "??" then
		return tty:sub(1, 1) == "/" and tty or "/dev/" .. tty
	end
end

function M.show(win, url, worktree)
	worktree = worktree or vim.t.aero_worktree

	if not worktree then
		notify("select a worktree first")
		return
	end

	url = url or opening[worktree]
	opening[worktree] = nil
	local s = instances[worktree]

	if s and api.nvim_buf_is_valid(s.buf) then
		if win then
			api.nvim_win_set_buf(win, s.buf)
		end

		refresh()
		return s
	end

	local options = require("aero.config").options.browser
	local ready, failure = require("aero.browser.setup").check(true)

	if not ready then
		failures[worktree] = failure
		require("aero.browser.setup").show(win, worktree, failure)
		return nil, failure
	end

	assert(type(options.cell_width) == "number" and options.cell_width > 0, "browser.cell_width must be positive")
	assert(type(options.cell_height) == "number" and options.cell_height > 0, "browser.cell_height must be positive")
	local tty = tty_path()

	if not tty or #api.nvim_list_uis() == 0 then
		failure = {
			code = "browser_unavailable",
			message = "Could not resolve a terminal device for the attached Neovim UI.",
			next_step = "Run Neovim in a local terminal with Kitty graphics support. In tmux, ensure TMUX_PANE identifies Neovim's pane, tmux is on Neovim's PATH, and a local client is attached, then retry.",
		}
		failures[worktree] = failure
		require("aero.browser.setup").show(win, worktree, failure)
		return nil, failure
	end

	failures[worktree] = nil
	setup()
	serial = serial + 1
	s = {
		worktree = worktree,
		tty = tty,
		buf = api.nvim_create_buf(false, true),
		socket = vim.fn.tempname() .. ".sock",
		cell = { options.cell_width, options.cell_height },
		image = 0x700000 + (vim.fn.getpid() % 4096) * 256 + serial,
		-- File transport requires the terminal to share the browser's filesystem.
		transport = ((vim.env.SSH_CONNECTION or "") ~= "" or (vim.env.SSH_TTY or "") ~= "") and "inline" or "file",
	}

	if options.auto_cell_size then
		s.cell = require("aero.browser.terminal").cell(tty) or s.cell
	end

	instances[worktree] = s

	if api.nvim_ui_send and vim.tbl_contains(ready.capabilities, "image-frames") then
		s.transport = "host"
		s.frames = require("aero.browser.frames").new(s.image, (vim.env.TMUX_PANE or "") ~= "", function(message)
			draw(s, message)
		end, function(message)
			local target = visible_window(s)
			stop(s)
			failures[worktree] = {
				code = "browser_frame_failed",
				message = "Browser frame delivery failed.",
				details = message,
				next_step = "Retry the browser. If frame delivery fails again, report the details below; terminal-browser was already detected successfully.",
			}
			require("aero.browser.setup").show(target, worktree, failures[worktree])
		end)
	end

	api.nvim_buf_set_name(s.buf, "aero://browser/" .. vim.fn.getpid() .. "/" .. serial)
	vim.bo[s.buf].bufhidden = "hide"
	vim.bo[s.buf].swapfile = false
	vim.bo[s.buf].filetype = "aero-browser"

	if win then
		api.nvim_win_set_buf(win, s.buf)
	end

	s.channel = api.nvim_open_term(s.buf, {
		on_input = function(_, _, _, data)
			if s.input then
				s.input(data)
			end
		end,
	})
	vim.bo[s.buf].scrollback = 0

	for lhs, modifier in pairs({ ["<C-Tab>"] = 5, ["<C-S-Tab>"] = 6 }) do
		vim.keymap.set("t", lhs, function()
			send(s, { type = "key", key = "tab", kind = "press", mods = { ctrl = true, shift = modifier == 6 } })
		end, { buffer = s.buf, desc = "Browser: switch page" })
	end

	s.input = require("aero.browser.input").new(function(message)
		send(s, message)
	end, s.cell)
	api.nvim_chan_send(s.channel, "\027[?1000h\027[?1006h\027[?2004hStarting terminal-browser…")
	api.nvim_create_autocmd("BufWipeout", {
		buffer = s.buf,
		once = true,
		callback = function()
			stop(s)
		end,
	})
	s.server = assert(uv.new_pipe(false))
	local ok, err = s.server:bind(s.socket)

	if not ok then
		stop(s)
		failure = { code = "browser_startup_failed", message = tostring(err) }
		failures[worktree] = failure
		require("aero.browser.setup").show(win, worktree, failure)
		return nil, failure
	end

	uv.fs_chmod(s.socket, 384)
	s.server:listen(1, function(error)
		if error or s.connection then
			return
		end

		local connection = assert(uv.new_pipe(false))
		s.server:accept(connection)
		s.connection = connection
		local pending = ""
		connection:read_start(function(read_error, data)
			if read_error or not data then
				vim.schedule(function()
					stop(s)
				end)
				return
			end

			pending = pending .. data
			while pending:find("\n", 1, true) do
				local last = pending:find("\n", 1, true)
				local line = pending:sub(1, last - 1)
				pending = pending:sub(last + 1)
				vim.schedule(function()
					if s.stopped then
						return
					end

					local decoded, message = pcall(vim.json.decode, line)

					if not decoded or type(message) ~= "table" then
						return
					end

					if message.type == "join" then
						s.joined = true
						local target = visible_window(s)
						local init = target and size(s, target, "init")
							or {
								type = "init",
								cols = 80,
								rows = 24,
								width = 80 * s.cell[1],
								height = 24 * s.cell[2],
								cell = s.cell,
							}
						init.imageId, init.transport, init.focused =
							s.image, s.transport, target == api.nvim_get_current_win()

						if s.frames then
							s.frames.resize(init)
							s.size = table.concat({ init.cols, init.rows, s.cell[1], s.cell[2] }, ":")
						end

						send(s, init)
					elseif message.type == "placed" then
						draw(s, message)
					elseif message.type == "frame" and s.frames then
						s.frames.push(message)
					elseif message.type == "clipboard" and type(message.text) == "string" then
						vim.fn.setreg("+", message.text)
					end
				end)
			end
		end)
	end)
	local command =
		vim.list_extend(vim.deepcopy(options.cmd), { "open", url or "about:blank", "--parent-tty=" .. s.socket })
	s.job = vim.fn.jobstart(command, {
		cwd = worktree,
		env = {
			PIXEL_EMBED = s.socket,
			PIXEL_TTY = tty,
			PIXEL_PANE = "",
			TERMINAL_BROWSER_NO_MERGE = "1",
		},
		on_stderr = function(_, data)
			s.stderr = ((s.stderr or "") .. table.concat(data, "\n")):sub(-4096)
		end,
		on_exit = function(_, code)
			if not s.stopped then
				stop(s)

				if code ~= 0 then
					failures[worktree] = {
						code = "browser_startup_failed",
						message = "terminal-browser exited with status " .. code,
						details = s.stderr,
						next_step = "Run terminal-browser setup outside Neovim and retry.",
					}
					require("aero.browser.setup").show(visible_window(s), worktree, failures[worktree])
					notify(
						failures[worktree].message .. ": " .. (s.stderr or "run terminal-browser setup outside Neovim")
					)
				end
			end
		end,
	})

	if s.job <= 0 then
		stop(s)
		failure = { code = "browser_startup_failed", message = "Could not launch terminal-browser." }
		failures[worktree] = failure
		require("aero.browser.setup").show(win, worktree, failure)
		return nil, failure
	end

	vim.defer_fn(function()
		if not s.stopped and not s.joined then
			stop(s)
			failures[worktree] = {
				code = "browser_startup_failed",
				message = "Embedding handshake timed out; check terminal-browser setup and embedding support.",
			}
			require("aero.browser.setup").show(visible_window(s), worktree, failures[worktree])
			notify(failures[worktree].message)
		end
	end, 20000)
	return s
end

-- Discovery uses a unique parent-tty marker supplied at launch. Never infer the
-- target from the active outer terminal tab: it can contain several worktrees.
local function discover(s, callback, quiet)
	local cmd = vim.list_extend(vim.deepcopy(require("aero.config").options.browser.cmd), { "ls", "--all", "--json" })
	vim.system(cmd, { text = true, cwd = s.worktree, timeout = 3000 }, function(result)
		vim.schedule(function()
			if s.stopped then
				if quiet then
					callback(
						nil,
						failures[s.worktree] or { code = "stale_target", message = "Browser stopped; open it again." }
					)
				end

				return
			end

			local ok, listing = pcall(vim.json.decode, result.stdout or "")

			if result.code == 0 and ok and type(listing) == "table" then
				for _, browser in ipairs(listing.browsers or {}) do
					if browser.parentTty == s.socket then
						callback(browser)
						return
					end
				end
			end

			local failure = {
				code = "browser_unavailable",
				message = "Browser target unavailable; wait for startup and try again.",
			}

			if quiet then
				callback(nil, failure)
			else
				notify(failure.message)
			end
		end)
	end)
end

local function control(s, browser, message, callback)
	local connection = assert(uv.new_pipe(false))
	local timer = assert(uv.new_timer())
	local complete = false
	local function finish(result, failure)
		if complete then
			return
		end

		complete = true
		close_handle(timer)
		close_handle(connection)
		vim.schedule(function()
			if callback then
				callback(result, failure)
			elseif failure then
				notify(failure.message)
			end
		end)
	end

	timer:start(5000, 0, function()
		finish(nil, { code = "browser_unavailable", message = "Browser control request timed out." })
	end)
	connection:connect(browser.socket, function(err)
		if err or s.stopped then
			finish(nil, { code = "browser_unavailable", message = tostring(err or "Browser stopped.") })
			return
		end

		local pending = ""
		connection:read_start(function(read_error, data)
			if read_error or not data then
				finish(nil, {
					code = "browser_unavailable",
					message = tostring(read_error or "Browser closed the control connection."),
				})
				return
			end

			pending = pending .. data
			local last = pending:find("\n", 1, true)

			if last then
				local ok, response = pcall(vim.json.decode, pending:sub(1, last - 1))

				if ok and type(response) == "table" and response.id == "aero" and response.ok then
					finish(response.data)
				else
					finish(nil, {
						code = "browser_action_failed",
						message = ok and tostring(response.error) or "Invalid browser control response.",
					})
				end
			end
		end)
		message = vim.tbl_extend("force", message, { id = "aero" })
		connection:write(vim.json.encode(message) .. "\n")
	end)
end

function M.instance(worktree)
	return instances[worktree]
end

function M.failure(worktree)
	return failures[worktree]
end

function M.discover(s, callback)
	return discover(s, callback, true)
end

M.control = control

local function attach(s, browser, page)
	local command = vim.list_extend(vim.deepcopy(require("aero.config").options.browser.cmd), {
		"action",
		"--browser",
		browser.key,
		"--tab",
		tostring(page.id),
		"--",
	})
	local quoted = vim.tbl_map(vim.fn.shellescape, command)
	local instruction = "Browser target for "
		.. s.worktree
		.. ":\n"
		.. page.url
		.. "\nUse this explicit command prefix for browser actions (do not use the active-tab default):\n"
		.. table.concat(quoted, " ")
		.. " snapshot\nReplace snapshot with the desired action. Finish with: "
		.. table.concat(
			vim.tbl_map(
				vim.fn.shellescape,
				vim.list_extend(vim.deepcopy(require("aero.config").options.browser.cmd), {
					"action",
					"done",
					"--browser",
					browser.key,
					"--tab",
					tostring(page.id),
				})
			),
			" "
		)
	local sessions = require("aero.session").list(s.worktree)

	if #sessions == 0 then
		notify("start an agent in this worktree before attaching a browser page")
		return
	end

	vim.ui.select(sessions, {
		prompt = "Attach browser page to agent",
		format_item = function(session)
			return session.name .. " (" .. session.agent .. ")"
		end,
	}, function(session)
		if session and not s.stopped then
			local ok, err = require("aero.compose").append(session, instruction)

			if not ok then
				notify(err)
			end
		end
	end)
end

function M.command(args)
	local action = args[1]
	local worktree = vim.t.aero_worktree

	if not worktree then
		notify("select a worktree first")
		return
	end

	if
		#args > (action == "open" and 2 or 1)
		or action and not vim.tbl_contains({ "open", "next", "prev", "pages", "attach", "stop" }, action)
	then
		notify("use :Aero browser [open <url-or-html-path>|next|prev|pages|attach|stop]")
		return
	end

	local s = instances[worktree]

	if action == "stop" then
		if s then
			stop(s)
		end

		return
	end

	if not action or action == "open" then
		local url = args[2]

		if action == "open" and not url then
			notify("use :Aero browser open <url-or-html-path>")
			return
		end

		if url and not url:match("^[%a][%w+.-]*:") then
			url = vim.fs.normalize(worktree .. "/" .. url)

			if args[2]:sub(1, 1) == "/" then
				url = vim.fs.normalize(args[2])
			end

			if vim.fn.filereadable(url) ~= 1 then
				notify("use a URL with a scheme or an existing local HTML file")
				return
			end
		end

		local existing = s ~= nil

		if not existing then
			opening[worktree] = url
		end

		local win = require("aero.navigation").code_window("browser")
		api.nvim_set_current_win(win)
		s = instances[worktree]

		if existing and s and url then
			discover(s, function(browser)
				control(s, browser, { cmd = "open-tab", url = url, cwd = worktree })
			end)
		end

		return
	end

	if not s then
		notify("open this worktree's browser first")
		return
	end

	discover(s, function(browser)
		local pages = browser.tabs or {}

		if #pages == 0 then
			notify("no browser pages available")
			return
		end

		if action == "next" or action == "prev" then
			local active = 1

			for index, page in ipairs(pages) do
				if page.active then
					active = index
				end
			end

			local page = pages[(active - 1 + (action == "next" and 1 or -1)) % #pages + 1]
			control(s, browser, { cmd = "activate-tab", tab = page.id })
			return
		end

		vim.ui.select(pages, {
			prompt = action == "attach" and "Attach browser page" or "Browser pages",
			format_item = function(page)
				return (page.active and "* " or "  ")
					.. (page.title ~= "" and page.title or page.url)
					.. " — "
					.. page.url
			end,
		}, function(page)
			if not page or s.stopped then
				return
			end

			if action == "attach" then
				attach(s, browser, page)
			else
				control(s, browser, { cmd = "activate-tab", tab = page.id })
			end
		end)
	end)
end

return M
