vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_DATA_HOME = root .. "/data"
vim.fn.writefile({ "entry", "dispatch", "result" }, root .. "/source.lua")
local reading = require("aero.reading")
local binding = { worktree = root, session_key = "test-session" }
local args = {
	title = "Entry to result",
	items = {
		{ id = "entry", path = "source.lua", lnum = 1, label = "Entry", note = "Start here" },
		{ id = "result", path = "source.lua", lnum = 3, label = "Result" },
	},
}
local result = assert(reading.publish(binding, args))
assert(#reading.load(root, result.id).items == 2)
vim.fn.setqflist({}, " ", { title = "Existing search", items = { { filename = root .. "/source.lua", lnum = 2 } } })
local previous = vim.fn.getqflist({ id = 0 }).id
vim.t.aero_worktree = root
vim.ui.select = function(items, _, callback)
	callback(items[1])
end
reading.command()
local qf = vim.fn.getqflist({ id = 0, items = 0, context = 0 })
assert(qf.id ~= previous and #qf.items == 2)
assert(qf.items[1].text == "[ ] Entry")
reading.command("toggle")
assert(reading.load(root, result.id).items[1].read)
args.id = result.id
args.items[1].label = "Updated entry"
assert(reading.publish(binding, args))
assert(vim.fn.getqflist()[1].text == "[x] Updated entry")
assert(not reading.load(root, result.id).items[2].read)
reading.command("next")
assert(vim.fn.line(".") == 3)
assert(not reading.load(root, result.id).items[2].read, "navigation must not mark read")
local invalid = vim.deepcopy(args)
invalid.items[1].path = "../outside.lua"
assert(not reading.publish(binding, invalid))
invalid = vim.deepcopy(args)
invalid.items[2].id = "entry"
assert(not reading.publish(binding, invalid))
assert(not reading.publish({ worktree = root, session_key = "other" }, args))
assert(reading.load(root, result.id).items[1].label == "Updated entry")

local executable = vim.env.AERO_MCP_EXECUTABLE
if executable then
	local config = require("aero.config").options
	config.reading.agent = { enabled = true, executable = executable }
	local agent = require("aero.reading_agent")
	local session = { key = binding.session_key, worktree = root, mcp_servers = { { name = "custom" } } }
	assert(agent.attach(session))
	assert(#session.mcp_servers == 2 and session.mcp_servers[2].name == "aero-reading")
	assert(agent.attach(session))
	assert(#session.mcp_servers == 2)
	agent.detach(session)
	assert(#session.mcp_servers == 1 and not session.reading_transport)
	local bridge = require("aero.tasks.bridge")
	local transport = assert(bridge.bind({ worktree = root, session_key = binding.session_key, reading_only = true }))
	local function call(method, params)
		local response
		vim.system(
			{ executable, "call", "--socket", transport.socket, method, vim.json.encode(params or {}) },
			{ text = true, env = { AERO_TASK_CREDENTIAL = transport.credential } },
			function(value)
				response = value
			end
		)
		assert(vim.wait(10000, function()
			return response ~= nil
		end))
		return response
	end
	assert(call("reading_list_publish", args).code == 0)
	assert(call("list_boards").code ~= 0)
	bridge.unbind(transport.credential)
	assert(call("reading_list_publish", args).code ~= 0)
	bridge.stop()
end
vim.fn.delete(root, "rf")
print("reading: ok")
