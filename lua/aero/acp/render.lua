-- Type-specific transcript layouts, with visual borders kept out of the actual text.
local api = vim.api
local config = require("aero.config")
local spinner = require("aero.spinner")
local usage = require("aero.acp.usage")
local todos = require("aero.acp.todos")
local M = {}
local ns = api.nvim_create_namespace("Aero.acp.render")
local tool_icons = { pending = "…", in_progress = "◐", completed = "✓", failed = "✗" }
local tool_names = {
	read = "Read",
	edit = "Edit",
	delete = "Delete",
	search = "Search",
	execute = "Command",
	fetch = "Fetch",
	think = "Thinking",
}

local function one_line(text)
	return (tostring(text or ""):gsub("%s*\r?\n%s*", " ⏎ "))
end

local function split(text)
	return vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })
end

local function text_lines(block)
	local text = block.shown and block.text:sub(1, block.shown) or block.text
	if block.cache_src ~= text then
		block.cache_src, block.cache = text, split(text)
	end
	return block.cache
end

local function content_text(content)
	if type(content) ~= "table" then
		return ""
	end
	if content.type == "text" then
		return content.text or ""
	elseif content.type == "resource_link" then
		return ("[%s](%s)"):format(content.name or content.uri, content.uri or "")
	elseif content.type == "resource" and content.resource then
		return content.resource.text or ("[%s]"):format(content.resource.uri or "")
	elseif content.type == "image" then
		return "[image]"
	end
	return ""
end

local function command_input(block)
	local input = block.rawInput
	if type(input) == "string" and block.tool_kind and block.tool_kind ~= "execute" then
		return nil
	end
	if type(input) == "table" then
		input = input.command or input.cmd
	end
	if type(input) == "table" then
		local parts = {}
		for _, part in ipairs(input) do
			part = tostring(part)
			table.insert(parts, part:match("^[%w_./:@%%=+-]+$") and part or vim.fn.shellescape(part))
		end
		input = table.concat(parts, " ")
	end
	return type(input) == "string" and input or nil
end

local function info_kind(block)
	if block.meta_kind then
		return block.meta_kind
	end
	-- Older saved histories contain untyped info blocks.
	if block.text:match("^[Cc]urrent model:") or block.text:match("^Model:") then
		return "model"
	elseif block.text:match("failed:") or block.text:match("^could not resume") then
		return "error"
	end
	local exit_code = tonumber(block.text:match("^agent exited %((%-?%d+)%)"))
	if exit_code and exit_code ~= 0 then
		return "error"
	end
	return "session"
end

function M.setup_highlights()
	for group, link in pairs({
		AeroChatUser = "String",
		AeroChatAgent = "Title",
		AeroChatThinking = "Comment",
		AeroChatTool = "Function",
		AeroChatCommand = "DiagnosticInfo",
		AeroChatMeta = "Comment",
		AeroChatError = "DiagnosticError",
		AeroChatSuccess = "DiagnosticOk",
		AeroChatPending = "DiagnosticWarn",
		AeroChatBorder = "Comment",
		AeroChatHeader = "CursorLine",
	}) do
		api.nvim_set_hl(0, group, { link = link, default = true })
	end
end

function M.build(chat, opts)
	opts = opts or {}
	local lines, marks, options = {}, {}, {}
	local max_lines = opts.export and math.huge
		or math.max(1, math.floor(tonumber(config.options.acp.max_tool_lines) or 20))
	local function push(text, group, style, prefix)
		table.insert(lines, text)
		if group or style then
			table.insert(marks, { line = #lines, group = group, style = style, prefix = prefix })
		end
	end
	local function body(list, group, border)
		for _, line in ipairs(list) do
			push(line, group, "body")
			marks[#marks].border_group = border
		end
	end
	local timestamp
	local function header(text, group, level)
		local suffix = timestamp and (" · " .. os.date("%Y-%m-%d %H:%M:%S", timestamp)) or ""
		push((level or "### ") .. text .. suffix, group, "header")
		if timestamp then
			marks[#marks].timestamp_col = #lines[#lines] - #suffix
		end
	end
	local function finish(group)
		push("", group, "footer")
		push("")
	end
	local function fenced(list, language, group, limit, command)
		local first_mark = #marks + 1
		limit = limit or max_lines
		local shown = vim.list_slice(list, 1, math.min(#list, limit))
		local length = 3
		for ticks in table.concat(shown, "\n"):gmatch("`+") do
			length = math.max(length, #ticks + 1)
		end
		local fence = string.rep("`", length)
		push(fence .. language, "AeroChatBorder", "body")
		for i, line in ipairs(shown) do
			push(line, nil, "body", command and (i == 1 and "│ $ " or "│   ") or nil)
		end
		if #list > limit then
			push(("… %d more lines"):format(#list - limit), "AeroChatMeta", "body")
		end
		push(fence, "AeroChatBorder", "body")
		for i = first_mark, #marks do
			marks[i].border_group = group
		end
	end
	local function output(text, label, group)
		if type(text) == "string" and text ~= "" then
			text = text:gsub("[\r\n]+$", "")
			if text == "" then
				return
			end
			push(label, "AeroChatMeta", "body")
			fenced(split(text), "text", group)
		end
	end
	local function tool(block)
		local entries = todos.block(block)
		if entries then
			header("Agent todos", "AeroChatTool")
			for _, row in ipairs(todos.rows(entries)) do push(row.text, row.group, "body") end
			finish("AeroChatTool")
			return
		end
		local command = command_input(block)
		if
			not command
			and block.tool_kind == "execute"
			and type(block.title) == "string"
			and block.title:find("\n", 1, true)
		then
			command = block.title
		end
		local execute = block.tool_kind == "execute" or command ~= nil
		local kind = execute and "Command" or tool_names[block.tool_kind] or "Tool call"
		local group = execute and "AeroChatCommand" or "AeroChatTool"
		local status = block.status or "pending"
		local running = chat.busy and (status == "pending" or status == "in_progress")
		local icon = running and spinner.frame() or tool_icons[status] or "•"
		local status_group = status == "failed" and "AeroChatError"
			or status == "completed" and "AeroChatSuccess"
			or "AeroChatPending"
		header(icon .. " " .. kind .. " · " .. status:gsub("_", " "), group)
		marks[#marks].status_group = status_group
		if block.title and block.title ~= command then
			push(one_line(block.title), group, "body")
		end
		if type(block.rawInput) == "table" and block.rawInput.cwd then
			push("cwd: " .. one_line(block.rawInput.cwd), "AeroChatMeta", "body")
		end
		for _, location in ipairs(block.locations or {}) do
			if location.path then
				local line = type(location.line) == "number" and (":" .. (location.line + 1)) or ""
				push(one_line(location.path) .. line, "AeroChatMeta", "body")
			end
		end
		if command and command ~= "" then
			push("Input", "AeroChatMeta", "body")
			fenced(split(command), "sh", group, max_lines, true)
		end
		for index, item in ipairs(block.content or {}) do
			if item.type == "diff" then
				push("Diff", "AeroChatMeta", "body")
				block.cache = block.cache or {}
				local cached = block.cache[index]
				local old, new = item.oldText or "", item.newText or ""
				if not cached or cached.old ~= old or cached.new ~= new then
					local diff = (vim.text and vim.text.diff or vim.diff)(old, new, { ctxlen = 2 })
					cached = { old = old, new = new, lines = split(vim.trim(diff or "")) }
					block.cache[index] = cached
				end
				local diff = { "--- " .. one_line(item.path), "+++ " .. one_line(item.path) }
				vim.list_extend(diff, cached.lines)
				fenced(diff, "diff", group, max_lines * 3)
			elseif item.type == "content" then
				local text = vim.trim(content_text(item.content))
				if text ~= "" then
					push("Output", "AeroChatMeta", "body")
					fenced(split(text), "text", group)
				end
			end
		end
		if #(block.content or {}) == 0 and block.rawOutput ~= nil and block.rawOutput ~= vim.NIL then
			local raw = block.rawOutput
			if type(raw) == "table" and (type(raw.stdout) == "string" or type(raw.stderr) == "string") then
				output(raw.stdout, "Output", group)
				output(raw.stderr, "stderr", group)
				local code = raw.exitCode or raw.exit_code
				if code ~= nil then
					push("Exit: " .. one_line(code), code == 0 and "AeroChatSuccess" or "AeroChatError", "body")
				end
			else
				output(type(raw) == "string" and raw or vim.inspect(raw), "Output", group)
			end
		end
		finish(group)
	end
	local speaker, index = nil, 1
	local block_lines = {}
	while index <= #chat.blocks do
		local block = chat.blocks[index]
		timestamp = block.timestamp
		block_lines[block] = #lines + 1
		if block.kind == "info" then
			local category = info_kind(block)
			local group = category == "error" and "AeroChatError" or "AeroChatMeta"
			header(category == "error" and "Error" or "Session", group)
			repeat
				block_lines[block] = #lines + 1
				body(split(vim.trim(block.text)), group)
				index = index + 1
				block = chat.blocks[index]
			until not block or block.kind ~= "info" or (info_kind(block) == "error") ~= (category == "error") or block.timestamp ~= timestamp
			finish(group)
		else
			if block.kind == "user" then
				header("You", "AeroChatUser", "## ")
				push("")
				body(text_lines(block), nil, "AeroChatUser")
				finish("AeroChatUser")
				speaker = "user"
			else
				if block.kind == "agent" and speaker == "agent" and timestamp then
					header("Message", "AeroChatAgent")
				end
				if speaker ~= "agent" then
					header(chat:agent_title(), "AeroChatAgent", "## ")
					push("")
					speaker = "agent"
				end
				if block.kind == "agent" then
					body(text_lines(block), nil, "AeroChatAgent")
					finish("AeroChatAgent")
				elseif block.kind == "thought" then
					header("Thinking", "AeroChatThinking")
					body(text_lines(block), "AeroChatThinking")
					finish("AeroChatThinking")
				elseif block.kind == "tool" then
					tool(block)
				elseif block.kind == "plan" then
					header("Plan", "AeroChatTool")
					for _, row in ipairs(todos.rows(todos.block(block) or {})) do
						push(row.text, row.group, "body")
					end
					finish("AeroChatTool")
				elseif block.kind == "permission" then
					header(block.answer and "Permission" or "Permission requested", "AeroChatPending")
					push(one_line(block.title), nil, "body")
					if block.answer then
						push("→ " .. one_line(block.answer), "AeroChatMeta", "body")
					else
						push("")
						for i, option in ipairs(block.options) do
							push(("  %d. %s"):format(i, one_line(option.name or option.optionId)), nil, "body")
							options[#lines] = { index = i, kind = option.kind }
						end
						push("")
						push(("<CR> or 1-%d to choose, <C-c> to cancel"):format(#block.options), "AeroChatMeta", "body")
					end
					finish("AeroChatPending")
				end
			end
			index = index + 1
		end
	end
	timestamp = nil
	for _, text in ipairs(chat.queue) do
		header("You (queued)", "AeroChatPending", "## ")
		push("")
		body(split(text), nil, "AeroChatPending")
		finish("AeroChatPending")
	end
	if chat.usage and (opts.export or config.options.acp.show_usage ~= false) then
		header("Usage", "AeroChatMeta")
		body(usage.lines(chat), "AeroChatMeta")
		finish("AeroChatMeta")
	end
	if chat.model_pending or chat.mode_pending then
		push(spinner.frame() .. " " .. (chat.model_pending or chat.mode_pending) .. "…", "AeroChatPending", "body")
	elseif chat.busy then
		local icon = chat.permission and config.options.icons.waiting or spinner.frame()
		push(icon .. " " .. chat:activity() .. " (<C-c> to cancel)", "AeroChatPending", "body")
	elseif chat.state == "starting" then
		push(spinner.frame() .. " starting " .. one_line(chat.s.agent) .. "…", "AeroChatMeta", "body")
	elseif chat.state == "ready" and #chat.blocks == 0 then
		push("Press i to write a prompt, :w or <C-s> to send it.", "AeroChatMeta")
	end
	return lines, marks, options, block_lines
end

function M.decorate(buf, lines, marks, first)
	if config.options.acp.decorations == false then
		api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		return
	end
	first = first or 1
	api.nvim_buf_clear_namespace(buf, ns, first - 1, -1)
	for _, mark in ipairs(marks) do
		if mark.line >= first then
			local text = lines[mark.line]
			local opts = { priority = 150, hl_mode = "combine" }
			if mark.group and #text > 0 then
				opts.hl_group, opts.end_col = mark.group, #text
			end
			if mark.style then
				local prefix = mark.prefix
					or (mark.style == "header" and "┌ " or mark.style == "footer" and "└─" or "│ ")
				opts.virt_text = { { prefix, mark.border_group or mark.group or "AeroChatBorder" } }
				opts.virt_text_pos = "inline"
			end
			if mark.style == "header" then
				opts.line_hl_group = "AeroChatHeader"
			end
			api.nvim_buf_set_extmark(buf, ns, mark.line - 1, 0, opts)
			if mark.status_group then
				local status = text:find(" · ", 1, true)
				if status then
					api.nvim_buf_set_extmark(buf, ns, mark.line - 1, status + #" · " - 1, {
						end_col = mark.timestamp_col or #text,
						hl_group = mark.status_group,
						priority = 160,
					})
				end
			end
			if mark.timestamp_col then
				api.nvim_buf_set_extmark(buf, ns, mark.line - 1, mark.timestamp_col, {
					end_col = #text, hl_group = "AeroChatMeta", priority = 170,
				})
			end
		end
	end
end

return M
