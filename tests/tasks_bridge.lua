-- AERO_MCP_EXECUTABLE=/absolute/aero-mcp nvim --headless -u NONE -l tests/tasks_bridge.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local executable = assert(vim.env.AERO_MCP_EXECUTABLE, "build aero-mcp and set AERO_MCP_EXECUTABLE")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	reports = { directory = "worktree" },
	tasks = { directory = "worktree", states = { "todo", "review" } },
})
local tasks = require("aero.tasks")
local ws = { root = root }
local board = assert(tasks.create_board(ws, "Bridge"))
local bridge = require("aero.tasks.bridge")
local empty_binding = assert(bridge.bind({ workspace = ws, board_id = board.metadata.id }))
local empty_result
vim.system({ executable, "call", "--socket", empty_binding.socket, "get_board" }, {
	text = true,
	env = { AERO_TASK_CREDENTIAL = empty_binding.credential },
}, function(value)
	empty_result = value
end)
assert(vim.wait(10000, function()
	return empty_result ~= nil
end))
assert(empty_result.code == 0, empty_result.stderr)
local empty_board = vim.json.decode(empty_result.stdout)
assert(#empty_board.states[1].tickets == 0)
local first_result
vim.system(
	{
		executable,
		"call",
		"--socket",
		empty_binding.socket,
		"create_ticket",
		vim.json.encode({
			operation_id = "first-ticket",
			expected_board_revision = empty_board.board_revision,
			title = "First ticket",
			target_state = "todo",
			body = "Initial content on an empty board.",
		}),
	},
	{ text = true, env = { AERO_TASK_CREDENTIAL = empty_binding.credential } },
	function(value)
		first_result = value
	end
)
assert(vim.wait(10000, function()
	return first_result ~= nil
end))
assert(first_result.code == 0, first_result.stderr)
local first = vim.json.decode(first_result.stdout)
assert(first.body:find("Initial content on an empty board.", 1, true))
local ticket = assert(tasks.read_ticket(board.path, first.ticket_path))
local execution = root .. "/execution"
vim.fn.mkdir(execution, "p")
local binding = assert(bridge.bind({ workspace = ws, board_id = board.metadata.id, ticket_id = ticket.metadata.id, worktree = execution }))
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
assert(#rpc(2, "tools/list", vim.empty_dict()).tools == 8)
local tool = rpc(3, "tools/call", { name = "aero_get_ticket", arguments = vim.empty_dict() })
assert(not tool.isError)
assert(vim.json.decode(tool.content[1].text).ticket_id == ticket.metadata.id)
local arguments = {
	operation_id = "mcp-create",
	expected_board_revision = updated.board_revision,
	title = "Created through MCP",
	task_type = "report",
	target_state = "todo",
	body = "## Requirements\n\nInitial content from the agent.",
}
local creation = rpc(4, "tools/call", { name = "aero_create_ticket", arguments = arguments })
assert(not creation.isError, vim.inspect(creation))
local created = vim.json.decode(creation.content[1].text)
assert(created.title == arguments.title and created.state == "todo")
assert(created.metadata.task_type == "report")
assert(created.body:find(arguments.body, 1, true))
assert(created.ticket_id ~= ticket.metadata.id)
local replay = rpc(5, "tools/call", { name = "aero_create_ticket", arguments = arguments })
assert(not replay.isError and vim.json.decode(replay.content[1].text).ticket_id == created.ticket_id)
assert(tasks.read_board(ws, board.path).count == 2)
local report_args = { operation_id = "mcp-report", name = "findings", body = "# Findings\n\nInvestigated through MCP.\n" }
local report_tool = rpc(6, "tools/call", { name = "aero_create_report", arguments = report_args })
assert(not report_tool.isError, vim.inspect(report_tool))
local report = vim.json.decode(report_tool.content[1].text)
assert(report.path == require("aero.storage").canonical(execution) .. "/.aero/reports/findings.md")
assert(require("aero.tasks.storage").read(report.path) == report_args.body)
local repeated = rpc(7, "tools/call", { name = "aero_create_report", arguments = report_args })
assert(not repeated.isError and vim.json.decode(repeated.content[1].text).path == report.path)
report_args.body = "Changed retry"
assert(rpc(8, "tools/call", { name = "aero_create_report", arguments = report_args }).isError)
report_args.operation_id = "collision"
assert(rpc(9, "tools/call", { name = "aero_create_report", arguments = report_args }).isError)
report_args.name = "../escape"
assert(rpc(10, "tools/call", { name = "aero_create_report", arguments = report_args }).isError)
assert(require("aero.tasks.storage").read(report.path) == "# Findings\n\nInvestigated through MCP.\n")
vim.fn.jobstop(job)
bridge.stop()
vim.fn.delete(root, "rf")
print("Go CLI / Lua socket / Markdown integration passed.")
vim.cmd("qa!")
