vim.opt.rtp:prepend(vim.fn.getcwd())
local api, uv = vim.api, vim.uv
require("aero.config").setup({ browser = { cmd = { "fixture-browser" } } })
local bridge = require("aero.tasks.bridge")
local a = assert(bridge.bind({ worktree = "/worktree/a", browser_only = true }))
local b = assert(bridge.bind({ worktree = "/worktree/b", browser_only = true }))
local reading = assert(bridge.bind({ worktree = "/worktree/a", reading_only = true }))
local installed = false
local executable = vim.fn.executable
vim.fn.executable = function(name)
	return name == "fixture-browser" and (installed and 1 or 0) or executable(name)
end
local original_buf, original_win = api.nvim_get_current_buf(), api.nvim_get_current_win()

local function call(binding, method, params)
	local client = assert(uv.new_pipe(false))
	local response, pending = nil, ""
	client:connect(binding.socket, function(err)
		assert(not err, err)

		client:read_start(function(read_error, data)
			assert(not read_error, read_error)

			if data then
				pending = pending .. data
				local last = pending:find("\n", 1, true)

				if last then
					response = vim.json.decode(pending:sub(1, last - 1))
				end
			end
		end)
		client:write(vim.json.encode({
			version = 1,
			id = "test",
			credential = binding.credential,
			method = method,
			params = params or {},
		}) .. "\n")
	end)

	assert(
		vim.wait(3000, function()
			return response ~= nil
		end, 10),
		"bridge response timed out"
	)

	client:close()
	return response
end

local missing = call(a, "browser_open", { url = "https://example.com" })

assert(missing.error.code == "dependency_missing")
assert(missing.error.suggested_command:find("install", 1, true))
assert(missing.error.installation_url:find("terminal-browser", 1, true))
assert(api.nvim_get_current_buf() == original_buf and api.nvim_get_current_win() == original_win)
assert(call(a, "get_board").error.code == "INVALID_ARGUMENT")
assert(call(reading, "browser_pages").error.code == "INVALID_ARGUMENT")

installed = true
local instances, listings, launched, commands = {}, {}, {}, {}
local browser = {}
browser.instance = function(worktree)
	return instances[worktree]
end
browser.show = function(win, url, worktree)
	assert(win == nil, "agent open must not take a window")

	if instances[worktree] then
		return instances[worktree]
	end

	launched[#launched + 1] = { url = url, worktree = worktree }
	local s = { worktree = worktree }
	instances[worktree] = s
	listings[worktree] = {
		key = worktree == "/worktree/a" and "browser-a" or "browser-b",
		tabs = {
			{ id = 1, url = url, title = "App", targetId = "target-1", active = true },
		},
	}
	vim.defer_fn(function()
		s.joined = true
	end, 10)
	return s
end
browser.discover = function(s, callback)
	vim.defer_fn(function()
		callback(listings[s.worktree])
	end, 10)
end
browser.control = function(s, _, message, callback)
	if message.cmd == "open-tab" then
		local listing = listings[s.worktree]
		listing.tabs[#listing.tabs + 1] = { id = 2, url = message.url, title = "Second", targetId = "target-2" }
		callback({ openedTab = 2 })
	else
		assert(message.cmd == "agent-release")

		callback({ released = true })
	end
end
package.loaded["aero.browser"] = browser
vim.system = function(command, options, callback)
	commands[#commands + 1] = command

	assert(options.cwd == "/worktree/a")

	if command[8] == "screenshot" then
		local fd = assert(uv.fs_open(command[9], "w", 384))

		assert(uv.fs_write(fd, "fixture PNG", 0))

		uv.fs_close(fd)
	end

	vim.schedule(function()
		callback({ code = 0, stdout = '{"data":{"snapshot":"button @e1"}}' })
	end)
end

local first = call(a, "browser_open", { url = "https://example.com/a", worktree = "/worktree/b" })
local other = call(b, "browser_open", { url = "https://example.com/b" })

assert(first.result.page_id == "browser-a:1")
assert(other.result.page_id == "browser-b:1")
assert(launched[1].worktree == "/worktree/a")
assert(api.nvim_get_current_buf() == original_buf and api.nvim_get_current_win() == original_win)
assert(call(a, "browser_action", { page_id = other.result.page_id, action = "snapshot" }).error.code == "stale_target")
assert(#commands == 0)

local second = call(a, "browser_open", { url = "https://example.com/second" })

assert(second.result.page_id == "browser-a:2")
assert(#call(a, "browser_pages").result.pages == 2)

local snapshot = call(a, "browser_action", { page_id = first.result.page_id, action = "snapshot" })

assert(snapshot.result.output:find("@e1", 1, true))
assert(commands[1][4] == "browser-a" and commands[1][6] == "1")
assert(call(a, "browser_action", { page_id = first.result.page_id, action = "eval" }).error.code == "invalid_argument")

local screenshot = call(a, "browser_action", { page_id = first.result.page_id, action = "screenshot" })

assert(vim.base64.decode(screenshot.result.image.data) == "fixture PNG")
assert(screenshot.result.image.mime_type == "image/png")
assert(not uv.fs_stat(commands[2][9]))
assert(call(a, "browser_done", { page_id = first.result.page_id }).result.released)

bridge.unbind(a.credential)

assert(call(a, "browser_pages").error.code == "NOT_FOUND")

installed = false
require("aero.config").options.browser.agent.enabled = true
package.loaded["aero.tasks.install"] = {
	resolve = function()
		return "/fixture/aero-mcp"
	end,
}
local session = { key = "browser-agent", worktree = "/worktree/a", mcp_servers = {} }
local agent = require("aero.browser.agent")

assert(agent.attach(session))
assert(session.mcp_servers[1].name == "aero-browser")
assert(session.mcp_servers[1].args[5] == "browser")
assert(call(session.browser_transport, "browser_pages").error.code == "dependency_missing")

local expired = session.browser_transport
agent.detach(session)

assert(#session.mcp_servers == 0)
assert(call(expired, "browser_pages").error.code == "NOT_FOUND")

bridge.stop()
print(
	"browser tools: dependency guidance, async routing, worktree isolation, page targets, images, and revocation passed"
)
vim.cmd("qa!")
