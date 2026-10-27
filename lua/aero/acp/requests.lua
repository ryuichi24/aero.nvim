-- Incoming ACP filesystem and permission requests. Assigned task documents retain
-- their revision-checked task-tool path; permission callbacks stay runtime-only.
local api = vim.api
local M = {}

local function read_file(path, line, limit)
	local buf, lines = vim.fn.bufnr(path)

	if buf > 0 and api.nvim_buf_is_loaded(buf) then
		lines = api.nvim_buf_get_lines(buf, 0, -1, false)
	else
		local ok, result = pcall(vim.fn.readfile, path)

		if not ok then
			return nil, result
		end

		lines = result
	end

	local first = line or 1
	return table.concat(vim.list_slice(lines, first, limit and first + limit - 1 or #lines), "\n")
end

local function write_file(path, content)
	local lines, buf = vim.split(content, "\n", { plain = true }), vim.fn.bufnr(path)

	if buf > 0 and api.nvim_buf_is_loaded(buf) then
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		return pcall(api.nvim_buf_call, buf, function()
			vim.cmd("silent noautocmd write!")
		end)
	end

	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local ok, err = pcall(vim.fn.writefile, lines, path)
	vim.schedule(function()
		vim.cmd("checktime")
	end)
	return ok, err
end

function M.handle(chat, method, params, respond)
	if method == "fs/read_text_file" then
		local content, err = read_file(params.path, params.line, params.limit)

		if content then
			respond({ content = content })
		else
			respond(nil, { code = -32603, message = tostring(err) })
		end
	elseif method == "fs/write_text_file" then
		local path = require("aero.storage").canonical(params.path)

		for _, document in ipairs(chat.s.task_documents or {}) do
			if path == document then
				respond(nil, {
					code = -32603,
					message = "Assigned task documents must be updated through Aero task tools, using their expected revisions.",
				})
				return
			end
		end

		local ok, err = write_file(params.path, params.content or "")

		if ok then
			respond(vim.NIL)
		else
			respond(nil, { code = -32603, message = tostring(err) })
		end
	elseif method == "session/request_permission" then
		local allow

		for _, option in ipairs(params.options or {}) do
			if option.kind == "allow_once" or option.kind == "allow_always" then
				allow = allow or option

				if option.kind == "allow_once" then
					allow = option
					break
				end
			end
		end

		local tool = params.toolCall or {}
		local known = chat.tools[tool.toolCallId]
		local block = {
			kind = "permission",
			timestamp = os.time(),
			title = tool.title or (known and known.title) or "tool call",
			options = vim.deepcopy(params.options or {}),
		}
		table.insert(chat.blocks, block)

		if chat.auto_yes and allow then
			block.answer = (allow.name or allow.optionId) .. " (auto yes)"
			respond({ outcome = { outcome = "selected", optionId = allow.optionId } })
			chat:changed()
			return
		end

		if allow then
			local id = "aero:auto-yes"
			local used = {}

			for _, option in ipairs(block.options) do
				used[option.optionId] = true
			end

			while used[id] do
				id = id .. ":"
			end
			table.insert(block.options, {
				optionId = id,
				name = "Auto yes for this conversation",
				kind = "allow_once",
				auto_yes = allow.optionId,
			})
		end

		chat.permissions = chat.permissions or {}
		local request = { params = params, respond = respond, block = block }
		table.insert(chat.permissions, request)
		chat.permission = chat.permission or request
		require("aero.inbox").add(chat, "permission", block)
		chat:set_option_keys(true)
		chat:advance(true)
		chat.pending_focus = true
		chat:changed()

		if api.nvim_get_current_buf() ~= chat.buf then
			vim.notify(
				("Aero: %s in %s needs permission: %s (choose in the agent log, or :Aero prompt)"):format(
					chat.s.name,
					vim.fn.fnamemodify(chat.s.worktree, ":~"),
					block.title
				)
			)
		end
	else
		respond(nil, { code = -32601, message = "method not supported: " .. method })
	end
end

return M
