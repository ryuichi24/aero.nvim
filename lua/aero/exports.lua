-- Independent Markdown archives; session deletion never removes these files.
local config = require("aero.config")
local M = {}
local jobs = {}

local function directories(worktree)
	return {
		vim.fs.joinpath(vim.fn.stdpath("data"), "Aero", "exports", vim.fn.sha256(worktree)),
		vim.fs.joinpath(worktree, config.options.exports.worktree_dir),
	}
end

function M.directory(worktree)
	local location = config.options.exports.location
	assert(location == "data" or location == "worktree", "exports.location must be data or worktree")
	return directories(worktree)[location == "worktree" and 2 or 1]
end

function M.list(worktree)
	local result, seen = {}, {}
	for _, dir in ipairs(directories(worktree)) do
		local scan = vim.uv.fs_scandir(dir)
		if scan then
			while true do
				local name, kind = vim.uv.fs_scandir_next(scan)
				if not name then
					break
				end
				local path = vim.fs.joinpath(dir, name)
				if kind == "file" and name:match("%.md$") and not seen[path] then
					seen[path] = true
					table.insert(result, { path = path, name = name:sub(1, -4) })
				end
			end
		end
	end
	table.sort(result, function(a, b)
		return a.name > b.name
	end)
	return result
end

local function write(path, text)
	local tmp = path .. "." .. vim.fn.getpid() .. ".tmp"
	local ok, err = pcall(function()
		vim.fn.mkdir(vim.fs.dirname(path), "p")
		vim.fn.writefile(vim.split(text, "\n", { plain = true }), tmp)
		local renamed, reason = vim.uv.fs_rename(tmp, path)
		assert(renamed, reason)
	end)
	if not ok then
		os.remove(tmp)
		vim.notify("Aero: could not export log: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	require("aero.session").emit()
	return true
end

function M.markdown(chat)
	local copy = vim.deepcopy(chat.blocks)
	for _, block in ipairs(copy) do
		block.shown, block.cache, block.cache_src = nil, nil, nil
	end
	local view = {
		blocks = copy,
		queue = {},
		usage = vim.deepcopy(chat.usage),
		state = "ready",
		busy = false,
		agent_title = function()
			return chat:agent_title()
		end,
	}
	local lines = require("aero.acp.render").build(view, { export = true })
	local header = {
		"# " .. chat.s.name:gsub("[%c]", " "),
		"",
		"- Worktree: " .. chat.s.worktree,
		"- Agent: " .. chat.s.agent,
		"- Session: " .. (chat.session_id or chat.saved_session_id or "unknown"),
		"- Exported: " .. os.date("%Y-%m-%d %H:%M:%S %z"),
		"",
	}
	vim.list_extend(header, lines)
	-- Preserve structured inputs/outputs and full old/new diff text as well as the readable rendering.
	for _, block in ipairs(copy) do
		if block.kind == "tool" then
			local data = vim.json.encode(block)
			local length = 3
			for ticks in data:gmatch("`+") do
				length = math.max(length, #ticks + 1)
			end
			local fence = string.rep("`", length)
			vim.list_extend(
				header,
				{ "", "### Tool protocol data · " .. tostring(block.id or ""), "", fence .. "json", data, fence }
			)
		end
	end
	return table.concat(header, "\n")
end

local function readable(chat, path, source)
	local Client = require("aero.acp.client")
	local agent = config.options.agents[chat.s.agent]
	local cmd = type(agent.cmd) == "function" and agent.cmd(chat.s) or agent.cmd
	local client, done, output = nil, false, {}
	local progress = require("aero.exports_progress").start(chat.s.name)
	local received = 0
	local stage = "start"
	local function finish(err)
		if done then
			return
		end
		done = true
		progress.close()
		if client then
			jobs[client] = nil
			client:stop()
		end
		if err then
			local detail = type(err) == "table" and tostring(err.message) or tostring(err)
			if type(err) == "table" and err.data ~= nil and err.data ~= vim.NIL then
				detail = detail .. "\n" .. vim.inspect(err.data)
			end
			vim.notify("Aero: readable export failed (" .. stage .. "): " .. detail, vim.log.levels.ERROR)
		elseif vim.trim(table.concat(output)) == "" then
			vim.notify("Aero: readable export returned no text", vim.log.levels.WARN)
		elseif
			write(
				path,
				"<!-- AI-formatted copy; original: "
					.. vim.fs.basename(path):gsub("%-readable%.md$", ".md")
					.. " -->\n\n"
					.. table.concat(output)
			)
		then
			vim.notify("Aero: saved readable log: " .. path)
		end
	end
	local err
	client, err = Client.spawn(cmd, {
		cwd = chat.s.worktree,
		env = agent.env,
		on_notification = function(method, params)
			local u = params.update
			if
				method == "session/update"
				and u
				and u.sessionUpdate == "agent_message_chunk"
				and u.content
				and u.content.type == "text"
			then
				table.insert(output, u.content.text or "")
				received = received + #(u.content.text or "")
				progress.update("Writing Markdown", received)
			elseif method == "session/update" and u and u.sessionUpdate == "agent_thought_chunk" then
				progress.update("Agent thinking")
			elseif
				method == "session/update"
				and u
				and (u.sessionUpdate == "tool_call" or u.sessionUpdate == "tool_call_update")
			then
				progress.update("Agent working")
			end
		end,
		on_request = function(method, _, respond)
			if method == "session/request_permission" then
				respond({ outcome = { outcome = "cancelled" } })
			else
				respond(nil, { code = -32601, message = "Export formatting does not provide file or terminal access" })
			end
		end,
		on_exit = function(code)
			if not done then
				finish("agent exited (" .. code .. ")")
			end
		end,
	})
	if not client then
		return finish(err or "could not start agent")
	end
	jobs[client] = true
	stage = "initialize"
	progress.update("Initializing agent")
	client:request("initialize", {
		protocolVersion = 1,
		clientCapabilities = vim.empty_dict(),
		clientInfo = { name = "Aero.nvim", title = "Aero.nvim", version = "0.1.0" },
	}, function(init_err)
		if init_err then
			return finish(init_err)
		end
		stage = "session/new"
		progress.update("Creating formatting conversation")
		client:request("session/new", { cwd = chat.s.worktree, mcpServers = {} }, function(new_err, res)
			if new_err then
				return finish(new_err)
			end
			stage = "session/prompt"
			progress.update("Agent preparing readable log")
			client:request("session/prompt", {
				sessionId = res.sessionId,
				prompt = {
					{
						type = "text",
						text = config.options.exports.rewrite_instructions .. "\n\n" .. source,
					},
				},
			}, function(prompt_err, response)
				finish(
					prompt_err
						or (
							response
								and response.stopReason ~= "end_turn"
								and "formatting stopped: " .. tostring(response.stopReason)
							or nil
						)
				)
			end)
		end)
	end)
	vim.notify("Aero: creating readable log…")
end

function M.export(chat, opts)
	local text = M.markdown(chat)
	local name = os.date("%Y%m%d-%H%M%S") .. "-" .. chat.s.name:gsub("[^%w_-]", "-")
	local dir = M.directory(chat.s.worktree)
	local path = vim.fs.joinpath(dir, name .. ".md")
	local n = 1
	while vim.uv.fs_stat(path) do
		n = n + 1
		path = vim.fs.joinpath(dir, name .. "-" .. n .. ".md")
	end
	if not write(path, text) then
		return
	end
	vim.notify("Aero: exported log: " .. path)
	if opts then
		if opts.readable then
			readable(chat, path:gsub("%.md$", "-readable.md"), text)
		end
		return path
	end
	vim.ui.select({ "Keep original only", "Create AI-formatted copy" }, {
		prompt = "Also create a readable copy? (uses a new agent conversation and tokens)",
	}, function(choice)
		if choice == "Create AI-formatted copy" then
			readable(chat, path:gsub("%.md$", "-readable.md"), text)
		end
	end)
	return path
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		for client in pairs(jobs) do
			client:stop()
		end
	end,
})

return M
