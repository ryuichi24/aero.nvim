-- Type-specific transcript layouts, with visual borders kept out of the actual text.
local api = vim.api
local config = require("aero.config")
local spinner = require("aero.spinner")
local usage = require("aero.acp.usage")
local todos = require("aero.acp.todos")
local images = require("aero.acp.images")
local reveal = require("aero.acp.reveal")
local M = {}
local ns = api.nvim_create_namespace("Aero.acp.render")
local tool_cache = setmetatable({}, { __mode = "k" })
local text_cache = setmetatable({}, { __mode = "k" })
local diff_cache = setmetatable({}, { __mode = "k" })
local tool_cache_fields = {
	"title",
	"status",
	"tool_kind",
	"timestamp",
	"rawInput",
	"rawOutput",
	"content",
	"locations",
}
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

local function text_lines(block, export)
	local text = export and block.text or reveal.text(block)
	local cached = text_cache[block]

	if not cached or cached.source ~= text then
		cached = { source = text, lines = split(text) }
		text_cache[block] = cached
	end

	return cached.lines
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

	local function build_tool(block)
		local entries = todos.block(block)

		if entries then
			header("Agent todos", "AeroChatTool", "#### ")

			for _, row in ipairs(todos.rows(entries)) do
				push(row.text, row.group, "body")
			end

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
		local title = block.title and (" · " .. vim.fn.strcharpart(one_line(block.title), 0, 100)) or ""
		header(icon .. " " .. kind .. " · " .. status:gsub("_", " "), group, "#### ")
		marks[#marks].spinner_col = running and #"#### " or nil
		marks[#marks].status_group = status_group

		-- Keep the established status/timestamp prefix, with a useful collapsed-call label.
		if title ~= "" then
			lines[#lines] = lines[#lines] .. title
		end

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
				diff_cache[block] = diff_cache[block] or {}
				local cached = diff_cache[block][index]
				local old, new = item.oldText or "", item.newText or ""

				if not cached or cached.old ~= old or cached.new ~= new then
					local diff = (vim.text and vim.text.diff or vim.diff)(old, new, { ctxlen = 2 })
					cached = { old = old, new = new, lines = split(vim.trim(diff or "")) }
					diff_cache[block][index] = cached
				end

				local diff = { "--- " .. one_line(item.path), "+++ " .. one_line(item.path) }
				vim.list_extend(diff, cached.lines)
				fenced(diff, "diff", group, max_lines * 3)
			elseif item.type == "content" and item.content and item.content.type == "image" then
				push(images.markdown(item.content, opts.export), nil, "body")
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

	local function tool(block)
		-- Protocol updates replace content/input/output tables. Keep caches outside
		-- the blocks so history and export never copy editor-only layout data.
		if opts.export then
			return build_tool(block)
		end

		local running = chat.busy
			and (block.status == nil or block.status == "pending" or block.status == "in_progress")
		local cached = tool_cache[block]
		local valid = cached and cached.limit == max_lines and not running

		for _, field in ipairs(tool_cache_fields) do
			if not cached or cached[field] ~= block[field] then
				valid = false
				break
			end
		end

		if valid then
			local offset = #lines
			vim.list_extend(lines, cached.lines)

			for _, mark in ipairs(cached.marks) do
				local copy = vim.tbl_extend("force", mark, { line = offset + mark.line })
				table.insert(marks, copy)
			end

			return
		end

		local first_line, first_mark = #lines, #marks
		build_tool(block)

		if running then
			tool_cache[block] = nil
			return
		end

		cached = { limit = max_lines, lines = vim.list_slice(lines, first_line + 1), marks = {} }

		for i = first_mark + 1, #marks do
			table.insert(cached.marks, vim.tbl_extend("force", marks[i], { line = marks[i].line - first_line }))
		end

		for _, field in ipairs(tool_cache_fields) do
			cached[field] = block[field]
		end

		tool_cache[block] = cached
	end

	local index = 1
	local block_lines, sections = {}, {}
	local turn, turn_count, tools = nil, 0, nil

	local function close_tools()
		if not tools then
			return
		end

		if opts.export then
			push("</details>")
			push("")
		end

		tools.last = #lines
		local summary = ("Tools · %d call%s"):format(tools.count, tools.count == 1 and "" or "s")
		local counts = {}

		for _, kind in ipairs(tools.order) do
			table.insert(counts, tools.counts[kind] .. " " .. kind)
		end

		summary = summary .. " · " .. table.concat(counts, ", ")

		if tools.failed > 0 then
			summary = summary .. (" · %d failed"):format(tools.failed)
		end

		lines[tools.first] = "### " .. summary
		tools = nil
	end

	local function close_turn()
		if turn then
			turn.last = #lines
		end
	end

	local function alert(block)
		if turn then
			turn.critical = (turn.critical or "") .. tostring(block) .. ";"
		end
	end

	if chat.blocks[1] and chat.blocks[1].kind ~= "user" then
		header("Session setup", "AeroChatMeta", "## ")
		push("")
	end

	while index <= #chat.blocks do
		local block = chat.blocks[index]

		if block.kind ~= "tool" then
			close_tools()
		end

		timestamp = block.timestamp
		local previous = chat.blocks[index - 1]

		if
			block.kind == "user" and (not previous or previous.kind ~= "user" or not (previous.image or block.image))
		then
			close_turn()
			turn_count = turn_count + 1
			local preview = one_line(block.image and "[image]" or block.text):gsub("%s+", " ")
			preview = vim.fn.strcharpart(preview, 0, 80) .. (vim.fn.strchars(preview) > 80 and "…" or "")
			turn = { kind = "turn", key = block, first = #lines + 1, closed = config.options.acp.collapsed.turns }
			table.insert(sections, turn)
			header(("Turn %d — %s"):format(turn_count, preview), "AeroChatUser", "## ")
			push("")
		end

		if block.kind == "permission" and not block.answer then
			alert(block)
		end

		if block.kind == "tool" then
			if not tools then
				tools = {
					kind = "tools",
					key = block,
					first = #lines + 1,
					closed = config.options.acp.collapsed.tool_groups,
					count = 0,
					failed = 0,
					counts = {},
					order = {},
				}
				table.insert(sections, tools)
				push("### Tools", "AeroChatTool", "header")
				push("")

				if opts.export then
					push("<details>")
					push("<summary>Tool calls and results</summary>")
					push("")
				end
			end

			local kind = tool_names[block.tool_kind] or "Tool"

			if not tools.counts[kind] then
				tools.counts[kind] = 0
				table.insert(tools.order, kind)
			end

			tools.counts[kind], tools.count = tools.counts[kind] + 1, tools.count + 1

			if block.status == "failed" then
				tools.failed = tools.failed + 1
				tools.critical = (tools.critical or "") .. tostring(block) .. ";"
				alert(block)
			end
		end

		block_lines[block] = #lines + 1

		if block.kind == "info" then
			local category = info_kind(block)
			local group = category == "error" and "AeroChatError" or "AeroChatMeta"
			header(category == "error" and "Error" or "Session", group)
			repeat
				if category == "error" then
					alert(block)
				end

				block_lines[block] = #lines + 1
				body(split(vim.trim(block.text)), group)
				index = index + 1
				block = chat.blocks[index]
			until not block
				or block.kind ~= "info"
				or (info_kind(block) == "error") ~= (category == "error")
				or block.timestamp ~= timestamp
			finish(group)
		else
			if block.kind == "user" then
				header("You", "AeroChatUser")
				push("")
				body(
					block.image and { images.markdown(block.image, opts.export) } or text_lines(block, opts.export),
					nil,
					"AeroChatUser"
				)
				finish("AeroChatUser")
			else
				if block.kind == "agent" then
					header("Message · " .. chat:agent_title(), "AeroChatAgent")
					push("")
					body(
						block.image and { images.markdown(block.image, opts.export) } or text_lines(block, opts.export),
						nil,
						"AeroChatAgent"
					)
					finish("AeroChatAgent")
				elseif block.kind == "thought" then
					local section = {
						kind = "thought",
						key = block,
						first = #lines + 1,
						closed = config.options.acp.collapsed.thinking,
					}
					table.insert(sections, section)
					header("Thinking", "AeroChatThinking")
					body(
						block.image and { images.markdown(block.image, opts.export) } or text_lines(block, opts.export),
						"AeroChatThinking"
					)
					finish("AeroChatThinking")
					section.last = #lines
				elseif block.kind == "tool" then
					local section = {
						kind = "tool",
						key = block,
						first = #lines + 1,
						closed = config.options.acp.collapsed.tools,
						critical = block.status == "failed",
					}
					table.insert(sections, section)
					tool(block)

					if opts.export then
						local data = vim.deepcopy(block)
						data.cache, data.cache_src, data.shown = nil, nil, nil
						push("#### Tool protocol data · " .. one_line(block.id), "AeroChatMeta")
						push("")
						fenced({ vim.json.encode(data) }, "json", "AeroChatTool")
						push("")
					end

					section.last = #lines
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
							options[#lines] = { index = i, kind = option.kind, block = block }
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
	close_tools()
	close_turn()
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
		marks[#marks].spinner_col = 0
	elseif chat.busy then
		local icon = chat.permission and config.options.icons.waiting or spinner.frame()
		push(icon .. " " .. chat:activity() .. " (<C-c> to cancel)", "AeroChatPending", "body")
		marks[#marks].spinner_col = 0
		marks[#marks].activity = true
	elseif chat.state == "starting" then
		push(spinner.frame() .. " starting " .. one_line(chat.s.agent) .. "…", "AeroChatMeta", "body")
		marks[#marks].spinner_col = 0
	elseif chat.state == "ready" and #chat.blocks == 0 then
		push("Press i to write a prompt, :w or <C-s> to send it.", "AeroChatMeta")
	end

	return lines, marks, options, block_lines, sections
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
					end_col = #text,
					hl_group = "AeroChatMeta",
					priority = 170,
				})
			end
		end
	end
end

return M
