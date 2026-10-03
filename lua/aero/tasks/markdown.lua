local fm = require("aero.tasks.frontmatter")
local storage = require("aero.tasks.storage")
local M = {}

function M.state_name(name)
	return type(name) == "string"
		and vim.trim(name) ~= ""
		and name == vim.trim(name)
		and not name:find("[%c#]")
		and not name:find("^```")
		and not name:find("^~~~")
end

function M.label(text)
	return text:gsub("\\", "\\\\"):gsub("([%[%]])", "\\%1")
end

function M.destination(text)
	return (text:gsub("([^%w%-%._~/])", function(c)
		return ("%%%02X"):format(c:byte())
	end))
end

local function decode(text)
	return (text:gsub("%%(%x%x)", function(hex)
		return string.char(tonumber(hex, 16))
	end))
end

local function link(line)
	local start = line:match("^%s*[-*+]%s+()")
	if not start or line:sub(start, start) ~= "[" then
		return nil
	end
	local label, i = {}, start + 1
	while i <= #line do
		local c = line:sub(i, i)
		if c == "\\" and i < #line then
			table.insert(label, line:sub(i + 1, i + 1))
			i = i + 2
		elseif c == "]" then
			break
		else
			table.insert(label, c)
			i = i + 1
		end
	end
	if line:sub(i, i + 1) ~= "](" then
		return nil
	end
	local rest = line:sub(i + 2)
	local destination, trailing = rest:match("^<([^<>]*)>%)%s*(.*)$")
	if not destination then
		local chars, depth, at = {}, 0, 1
		while at <= #rest do
			local c = rest:sub(at, at)
			if c == "\\" and at < #rest then
				table.insert(chars, rest:sub(at + 1, at + 1))
				at = at + 2
			elseif c == ")" and depth == 0 then
				destination, trailing = table.concat(chars), vim.trim(rest:sub(at + 1))
				break
			elseif c:match("%s") then
				break
			else
				if c == "(" then
					depth = depth + 1
				elseif c == ")" then
					depth = depth - 1
				end
				table.insert(chars, c)
				at = at + 1
			end
		end
	end
	if not destination or (trailing ~= "" and not trailing:match("^<!%-%-.*%-%->$")) then
		return nil
	end
	return table.concat(label), decode(destination)
end

function M.parse(text, kind, path)
	local lines = storage.lines(text)
	local metadata, err = fm.parse(lines, kind)
	local finish = metadata and metadata.finish or 0
	if not metadata and lines[1] == "---" then
		for i = 2, #lines do
			if lines[i] == "---" then
				finish = i
				break
			end
		end
	end
	local doc = {
		lines = lines,
		text = text,
		path = path,
		frontmatter = metadata,
		metadata = metadata and metadata.data,
		diagnostics = metadata and vim.deepcopy(metadata.errors) or { err },
		states = {},
	}
	local fence, fence_length, state
	local seen_states, seen_tickets = {}, {}
	for i = finish + 1, #lines do
		local line = lines[i]
		local marker = line:match("^%s*(```+)") or line:match("^%s*(~~~+)")
		if marker then
			if not fence then
				fence, fence_length = marker:sub(1, 1), #marker
			elseif marker:sub(1, 1) == fence and #marker >= fence_length and line:match("^%s*[`~]+%s*$") then
				fence = nil
			end
		elseif not fence and kind == "board" then
			local name = line:match("^ ? ? ?##%s+(.+)$")
			if name then
				name = vim.trim(name:gsub("%s+#+%s*$", ""))
				if state then
					state.last = i - 1
				end
				state = { name = name, first = i, last = #lines, entries = {} }
				table.insert(doc.states, state)
				if not M.state_name(name) or seen_states[name] then
					table.insert(doc.diagnostics, "invalid or duplicate state: " .. name)
				end
				seen_states[name] = true
			else
				local title, destination = link(line)
				if title then
					local entry =
						{ label = title, destination = destination, line = i, raw = line, state = state and state.name }
					entry.path, entry.error = storage.ticket_path(path, destination)
					if not state then
						entry.error = "ticket reference outside a state"
					end
					if entry.path and seen_tickets[entry.path] then
						entry.error = "duplicate ticket reference: " .. destination
					end
					if entry.path then
						seen_tickets[entry.path] = true
					end
					if entry.error then
						table.insert(doc.diagnostics, entry.error)
					end
					if state then
						table.insert(state.entries, entry)
					end
				elseif line:match("^%s*[-*+]%s+%[") and not line:match("^%s*[-*+]%s+%[[ xX]%]") then
					table.insert(doc.diagnostics, "malformed ticket reference at line " .. i)
				end
			end
		end
	end
	if kind == "board" and #doc.states == 0 then
		table.insert(doc.diagnostics, "board has no states")
	end
	doc.valid = #doc.diagnostics == 0
	return doc
end

function M.entry(ticket)
	return "- ["
		.. M.label(ticket.metadata.title)
		.. "]("
		.. M.destination("tickets/" .. vim.fs.basename(ticket.path))
		.. ")"
end

function M.title(lines, old, new, finish)
	local out = vim.deepcopy(lines)
	local fence, length
	for i = finish + 1, #out do
		local marker = out[i]:match("^%s*(```+)") or out[i]:match("^%s*(~~~+)")
		if marker then
			if not fence then
				fence, length = marker:sub(1, 1), #marker
			elseif marker:sub(1, 1) == fence and #marker >= length and out[i]:match("^%s*[`~]+%s*$") then
				fence = nil
			end
		elseif not fence and out[i] == "# " .. old then
			out[i] = "# " .. new
			break
		end
	end
	return out
end

function M.state(doc, name)
	for _, state in ipairs(doc.states) do
		if state.name == name then
			return state
		end
	end
end

function M.insert(lines, state, raw, position)
	local out = vim.deepcopy(lines)
	local at = state.entries[position or #state.entries + 1]
	at = at and at.line or (#state.entries > 0 and state.entries[#state.entries].line + 1 or state.first + 1)
	table.insert(out, at, raw)
	return out
end

-- Keep all non-reference lines in their original state, including fenced examples.
function M.placements(board, states, registry)
	local out = vim.list_slice(board.lines, 1, board.states[1].first - 1)
	for si, state in ipairs(board.states) do
		local references, insertion = {}, state.first + 1
		for ei, item in ipairs(state.entries) do
			references[item.line] = true
			if ei == 1 then
				insertion = item.line
			end
		end
		local function insert()
			for _, id in ipairs(states[si].ticket_ids) do
				table.insert(out, registry[id].raw)
			end
		end
		for line = state.first, state.last do
			if line == insertion then
				insert()
			end
			if not references[line] then
				table.insert(out, board.lines[line])
			end
		end
		if insertion > state.last then
			insert()
		end
	end
	return out
end

return M
