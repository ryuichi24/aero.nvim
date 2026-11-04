-- Agent-facing operations derive their worktree exclusively from the bridge binding.
local uv = vim.uv
local M = {}

local function failure(code, message)
	return { code = code, message = message }
end

local function page_id(browser, page)
	return browser.key .. ":" .. page.id
end

local function pages(browser)
	local result = {}

	for _, page in ipairs(browser.tabs or {}) do
		result[#result + 1] =
			{ page_id = page_id(browser, page), url = page.url, title = page.title, active = page.active }
	end

	return result
end

local function target(browser, id)
	for _, page in ipairs(browser.tabs or {}) do
		if page_id(browser, page) == id then
			return page
		end
	end
end

local function url_for(worktree, url)
	if type(url) ~= "string" or url == "" or url:find("%c") then
		return nil, failure("invalid_argument", "url must be a nonempty URL or HTML path.")
	end

	if url:match("^[%a][%w+.-]*:") then
		return url
	end

	local path = vim.fs.normalize(url:sub(1, 1) == "/" and url or worktree .. "/" .. url)

	if vim.fn.filereadable(path) ~= 1 then
		return nil,
			failure("invalid_argument", "Local file not found; use an existing HTML path or a URL with a scheme.")
	end

	return path
end

local function open(binding, params, callback)
	local browser = require("aero.browser")
	local url, err = url_for(binding.worktree, params.url)

	if not url then
		callback(nil, err)
		return
	end

	local existing = browser.instance(binding.worktree)
	local s, start_error = browser.show(nil, url, binding.worktree)

	if not s then
		callback(nil, start_error)
		return
	end

	local deadline = uv.hrtime() + 22e9
	local opened_tab
	local function ready()
		if binding.revoked then
			callback(nil, failure("NOT_FOUND", "Binding expired."))
			return
		end

		if s.stopped then
			callback(
				nil,
				browser.failure(binding.worktree) or failure("browser_unavailable", "Browser stopped during startup.")
			)
			return
		end

		if uv.hrtime() > deadline then
			callback(nil, failure("browser_unavailable", "Browser startup timed out; check terminal-browser setup."))
			return
		end

		if not s.joined then
			vim.defer_fn(ready, 100)
			return
		end

		browser.discover(s, function(found)
			if not found then
				vim.defer_fn(ready, 100)
				return
			end

			if binding.revoked then
				callback(nil, failure("NOT_FOUND", "Binding expired."))
				return
			end

			if not existing or opened_tab then
				local page = not existing and (found.tabs or {})[1] or nil

				if opened_tab then
					for _, candidate in ipairs(found.tabs or {}) do
						if candidate.id == opened_tab then
							page = candidate
						end
					end
				end

				if not page or type(page.targetId) ~= "string" then
					vim.defer_fn(ready, 100)
					return
				end

				callback({ page_id = page_id(found, page), url = page.url, title = page.title })
				return
			end

			browser.control(
				s,
				found,
				{ cmd = "open-tab", url = url, cwd = binding.worktree },
				function(result, control_error)
					if not result then
						callback(nil, control_error)
						return
					end

					if type(result.openedTab) == "number" then
						opened_tab = result.openedTab
						ready()
						return
					end

					callback(nil, failure("browser_unavailable", "New page target unavailable; list pages and retry."))
				end
			)
		end)
	end

	ready()
end

local function action_args(params, screenshot)
	if params.action == "snapshot" then
		return { "snapshot", "--json" }
	elseif params.action == "screenshot" then
		return { "screenshot", screenshot, "--json" }
	elseif params.action == "click" and type(params.ref) == "string" and params.ref:match("^@?e%d+$") then
		return { "click", params.ref, "--json" }
	elseif
		params.action == "fill"
		and type(params.ref) == "string"
		and params.ref:match("^@?e%d+$")
		and type(params.text) == "string"
	then
		return { "fill", params.ref, params.text, "--json" }
	elseif params.action == "press" and type(params.key) == "string" and params.key ~= "" then
		return { "press", params.key, "--json" }
	elseif params.action == "wait" and type(params.text) == "string" and params.text ~= "" then
		return { "wait", "--text", params.text, "--json" }
	elseif params.action == "scroll" and vim.tbl_contains({ "up", "down", "left", "right" }, params.direction) then
		local amount = params.amount or 500

		if type(amount) == "number" and amount == math.floor(amount) and amount >= 1 and amount <= 5000 then
			return { "scroll", params.direction, tostring(amount), "--json" }
		end
	end

	return nil,
		failure(
			"invalid_argument",
			"Use snapshot, screenshot, click(ref), fill(ref,text), press(key), wait(text), or scroll(direction,amount=1..5000)."
		)
end

local function action(binding, s, browser, page, params, callback)
	local screenshot = params.action == "screenshot" and (vim.fn.tempname() .. ".png") or nil
	local args, err = action_args(params, screenshot)

	if not args then
		callback(nil, err)
		return
	end

	local command = vim.list_extend(vim.deepcopy(require("aero.config").options.browser.cmd), {
		"action",
		"--browser",
		browser.key,
		"--tab",
		tostring(page.id),
		"--",
	})
	vim.list_extend(command, args)
	vim.system(command, { text = true, cwd = binding.worktree, timeout = 10000 }, function(result)
		vim.schedule(function()
			local response, action_error

			if binding.revoked or s.stopped then
				action_error = failure("stale_target", "Browser or binding expired; list pages again.")
			elseif result.code ~= 0 then
				action_error = failure("browser_action_failed", (result.stderr or ""):sub(1, 4096))
			else
				local output = result.stdout or ""
				response = {
					page_id = page_id(browser, page),
					action = params.action,
					output = output:sub(1, 480000),
					truncated = #output > 480000,
				}
			end

			if response and screenshot then
				response.truncated = #response.output > 4096
				response.output = response.output:sub(1, 4096)
				local stat = uv.fs_stat(screenshot)

				if not stat or stat.size > 512000 then
					response, action_error =
						nil,
						failure("browser_action_failed", "Screenshot missing or exceeds the 512 KB bridge image limit.")
				else
					local fd, read_error = uv.fs_open(screenshot, "r", 0)
					local data = fd and uv.fs_read(fd, stat.size, 0)

					if fd then
						uv.fs_close(fd)
					end

					if data then
						response.image = { mime_type = "image/png", data = vim.base64.encode(data) }
					else
						response, action_error =
							nil, failure("browser_action_failed", tostring(read_error or "Could not read screenshot."))
					end
				end
			end

			if screenshot then
				uv.fs_unlink(screenshot)
			end

			callback(response, action_error)
		end)
	end)
end

function M.call(binding, method, params, callback)
	if type(binding.worktree) ~= "string" or binding.worktree == "" then
		return nil, failure("invalid_argument", "Browser tools require a worktree-bound session.")
	end

	local dependency, err = require("aero.browser.setup").check(false)

	if not dependency then
		require("aero.browser.setup").show(nil, binding.worktree, err)
		return nil, err
	end

	if method == "browser_open" then
		open(binding, params, callback)
		return { pending = true }
	end

	local browser = require("aero.browser")
	local s = browser.instance(binding.worktree)

	if not s then
		return nil, failure("browser_unavailable", "Open this session's worktree browser with aero_browser_open first.")
	end

	browser.discover(s, function(found, discovery_error)
		if not found then
			callback(nil, discovery_error)
			return
		end

		if binding.revoked then
			callback(nil, failure("NOT_FOUND", "Binding expired."))
			return
		end

		if method == "browser_pages" then
			callback({ pages = pages(found) })
			return
		end

		local page = target(found, params.page_id)

		if not page then
			callback(
				nil,
				failure("stale_target", "Page does not belong to this worktree's current browser; list pages again.")
			)
			return
		end

		if method == "browser_done" then
			browser.control(s, found, { cmd = "agent-release" }, callback)
		else
			action(binding, s, found, page, params, callback)
		end
	end)
	return { pending = true }
end

return M
