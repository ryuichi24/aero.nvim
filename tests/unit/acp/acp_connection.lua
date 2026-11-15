-- Run from the repository root: python3 tests/run.py --unit acp_connection
vim.opt.rtp:prepend(vim.fn.getcwd())
local connection = require("aero.acp.connection")
local store = require("aero.store")
local saved_id, reloads
store.load = function()
	reloads = reloads + 1
end
store.find_session = function()
	return { acp_session_id = saved_id }
end
local function fixture(fields, persisted_id)
	saved_id, reloads = persisted_id, 0
	local calls = {}
	local chat = vim.tbl_extend("force", {
		s = { worktree = "/project", name = "Fixture", mcp_servers = { { name = "tools" } } },
		blocks = { { kind = "agent", text = "Saved transcript" } },
		tools = {},
		usage = { context = { used = 10, size = 100 } },
		usage_seen = { [1] = true },
		state = "starting",
		messages = {},
	}, fields or {})
	chat.client = {
		request = function(_, method, params, respond)
			table.insert(calls, { method = method, params = params, respond = respond })
		end,
	}
	chat.new_session = connection.new_session
	chat.info = function(self, message)
		table.insert(self.messages, message)
	end
	chat.ready = function(self, id, response)
		assert(not self.replaying, "ready must run after replay ends")

		self.accepted = { id = id, response = response }
	end
	chat.fail = function(self, method, err)
		self.failure = { method = method, error = err }
	end
	chat.resume_failed = function(self, id, err)
		self.failure = { id = id, error = err }
	end
	return chat, calls
end

local function initialize(calls, load_supported)
	calls[1].respond(nil, { agentInfo = { name = "Fixture" }, agentCapabilities = { loadSession = load_supported } })
end

local chat, calls = fixture(nil, "saved")
connection.handshake(chat, false)

assert(calls[1].method == "initialize")
assert(calls[1].params.clientCapabilities.terminal == false)

initialize(calls, true)

assert(reloads == 1 and calls[2].method == "session/new", "fresh startup must not load a saved conversation")
assert(calls[2].params.cwd == "/project" and calls[2].params.mcpServers == chat.s.mcp_servers)
assert(chat.usage == nil and chat.usage_seen == nil and chat.resumed == false)

local response = { sessionId = "new" }
calls[2].respond(nil, response)

assert(chat.accepted.id == "new" and chat.accepted.response == response)

chat, calls = fixture({ restored_conversation = true, cache_session_id = "saved" }, "saved")
local blocks, tools, usage = chat.blocks, chat.tools, chat.usage
connection.handshake(chat, true)
initialize(calls, true)

assert(calls[2].method == "session/load" and calls[2].params.sessionId == "saved")
assert(chat.replaying and chat.replay_from_cache)
assert(chat.blocks == blocks and chat.tools == tools and chat.usage == usage)

calls[2].respond(nil, {})

assert(chat.resumed and chat.accepted.id == "saved" and not chat.replaying)

chat, calls =
	fixture({ restored_conversation = true, cache_session_id = "saved", requested_session_id = "other" }, "saved")
blocks, tools, usage = chat.blocks, chat.tools, chat.usage
connection.handshake(chat, true)
initialize(calls, true)

assert(calls[2].params.sessionId == "other" and chat.replaying and not chat.replay_from_cache)
assert(chat.blocks ~= blocks and #chat.blocks == 0 and chat.tools ~= tools and chat.usage == nil)

local load_error = { code = -1, message = "Unavailable" }
calls[2].respond(load_error)

assert(chat.failure.id == "other" and chat.failure.error == load_error)
assert(chat.blocks == blocks and chat.tools == tools and chat.usage == usage, "failed recovery lost the original cache")
assert(
	not chat.replaying and not chat.accepted and #calls == 2,
	"failed strict load must not fall back to a new session"
)
assert(chat.saved_session_id == "saved")

chat, calls = fixture({ requested_session_id = "explicit" }, "saved")
connection.handshake(chat, true)
initialize(calls, false)

assert(#calls == 1 and chat.failure.id == "explicit" and chat.failure.error.code == -32601)

chat, calls = fixture({ requested_session_id = "explicit" })
connection.handshake(chat, true)
calls[1].respond(load_error)

assert(chat.failure.id == "explicit" and chat.failure.error == load_error and reloads == 0)

chat, calls = fixture()
connection.handshake(chat, false)
calls[1].respond(load_error)

assert(chat.failure.method == "initialize" and #calls == 1)

chat, calls = fixture({ restored_history = true })
connection.handshake(chat, true)
initialize(calls, true)

assert(calls[2].method == "session/new")
assert(chat.messages[1]:find("no saved ACP session ID", 1, true))

calls[2].respond(load_error)

assert(chat.failure.method == "session/new" and not chat.accepted)
assert(package.loaded["aero.acp.transcript"] == nil, "connection negotiation loaded editor presentation")

print("ACP connection negotiation/recovery tests passed.")
