-- AERO_MCP_EXECUTABLE=/absolute/aero-mcp nvim --headless -u NONE -l tests/tasks_bridge.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local executable = assert(vim.env.AERO_MCP_EXECUTABLE, "build aero-mcp and set AERO_MCP_EXECUTABLE")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	tasks = { directory = "worktree", states = { "todo", "review" } },
})
local tasks = require("aero.tasks")
local ws = { root = root }
local board = assert(tasks.create_board(ws, "Bridge"))
local ticket = assert(tasks.create_ticket(ws, board.path, "todo", "Assigned"))
local bridge = require("aero.tasks.bridge")
local binding = assert(bridge.bind({ workspace = ws, board_id = board.metadata.id, ticket_id = ticket.metadata.id }))
local pipe, framed, received = vim.uv.new_pipe(false), "", {}
pipe:connect(binding.socket, function(err)
	assert(not err, err)
	pipe:read_start(function(read_err, chunk)
		assert(not read_err, read_err)
		if not chunk then
			return
		end
		framed = framed .. chunk
		while framed:find("\n", 1, true) do
			local at = framed:find("\n", 1, true)
			local value = vim.json.decode(framed:sub(1, at - 1))
			framed = framed:sub(at + 1)
			received[value.id] = value
		end
	end)
	local first = vim.json.encode({
		version = 1,
		id = "partial",
		credential = binding.credential,
		method = "get_ticket",
	}) .. "\n"
	local second = vim.json.encode({ version = 1, id = "unauthorized", credential = "wrong", method = "get_ticket" })
		.. "\n"
	pipe:write(first:sub(1, 10))
	pipe:write(first:sub(11) .. second)
end)
assert(vim.wait(10000, function()
	return received.partial and received.unauthorized
end))
assert(received.partial.result.ticket_id == ticket.metadata.id)
assert(received.unauthorized.error.code == "NOT_FOUND")
pipe:close()
local function call(method, params)
	local result
	vim.system(
		{ executable, "call", "--socket", binding.socket, method, vim.json.encode(params or {}) },
		{ text = true, env = { AERO_TASK_CREDENTIAL = binding.credential } },
		function(value)
			result = value
		end
	)
	assert(
		vim.wait(10000, function()
			return result ~= nil
		end),
		"bridge request timed out"
	)
	assert(result.code == 0, result.stderr)
	return vim.json.decode(result.stdout)
end
local read = call("get_ticket")
assert(read.ticket_id == ticket.metadata.id and read.state == "todo")
local moved = call("move_ticket", {
	operation_id = "bridge-move",
	expected_board_revision = read.board_revision,
	expected_state = "todo",
	target_state = "review",
})
assert(moved.state == "review")
local updated = call("update_ticket_body", {
	operation_id = "bridge-body",
	expected_ticket_revision = moved.ticket_revision,
	body = "\nVerified through Go client.\n",
})
assert(updated.body:find("Verified through Go client.", 1, true))
-- Exercise the actual stdio executable, not just the socket CLI.
local responses, stdout, stderr = {}, "", ""
local job = vim.fn.jobstart({ executable, "serve", "--socket", binding.socket }, {
	env = { AERO_TASK_CREDENTIAL = binding.credential },
	on_stdout = function(_, chunks)
		stdout = stdout .. table.concat(chunks, "\n")
		while stdout:find("\n", 1, true) do
			local at = stdout:find("\n", 1, true)
			local line = stdout:sub(1, at - 1)
			stdout = stdout:sub(at + 1)
			local response = vim.json.decode(line)
			if response.id then
				responses[response.id] = response
			end
		end
	end,
	on_stderr = function(_, chunks)
		stderr = stderr .. table.concat(chunks, "\n")
	end,
})
assert(job > 0)
local function rpc(id, method, params)
	vim.fn.chansend(job, vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params }) .. "\n")
	assert(
		vim.wait(10000, function()
			return responses[id] ~= nil
		end),
		"MCP timeout: " .. stderr
	)
	assert(not responses[id].error, vim.inspect(responses[id]))
	return responses[id].result
end
rpc(1, "initialize", {
	protocolVersion = "2025-06-18",
	capabilities = vim.empty_dict(),
	clientInfo = { name = "aero-test", version = "1" },
})
vim.fn.chansend(job, vim.json.encode({ jsonrpc = "2.0", method = "notifications/initialized" }) .. "\n")
assert(#rpc(2, "tools/list", vim.empty_dict()).tools == 6)
local tool = rpc(3, "tools/call", { name = "aero_get_ticket", arguments = vim.empty_dict() })
assert(not tool.isError)
assert(vim.json.decode(tool.content[1].text).ticket_id == ticket.metadata.id)
vim.fn.jobstop(job)
bridge.stop()
vim.fn.delete(root, "rf")
print("Go CLI / Lua socket / Markdown integration passed.")
vim.cmd("qa!")
