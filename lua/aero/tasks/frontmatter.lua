local M = {}
local cache = {}
local versions = {}

local function execute(argv, opts)
	local ok, process = pcall(vim.system, argv, opts or { text = true })
	if not ok then
		return nil, "cannot run tasks.yq: " .. tostring(process)
	end
	local output = process:wait(10000)
	if output.code ~= 0 then
		return nil, "yq failed: " .. vim.trim(output.stderr or "")
	end
	return output.stdout
end

function M.check_yq()
	local binary = require("aero.config").options.tasks.yq
	if type(binary) ~= "string" or binary == "" then
		return nil, "tasks.yq must name the Mike Farah yq v4 executable"
	end
	if versions[binary] then
		return versions[binary]
	end
	local output, err = execute({ binary, "--version" })
	if not output then
		return nil, err .. "; install Mike Farah's Go-based yq v4"
	end
	if not output:find("github.com/mikefarah/yq", 1, true) or not output:match("version v4%.") then
		return nil, "Task management requires Mike Farah's Go-based yq v4; point tasks.yq to its executable"
	end
	versions[binary] = vim.trim(output)
	return versions[binary]
end

-- Fixed expressions only: user metadata is passed as data, never executable yq code.
local inspect = [[{
  "kind": kind,
  "data": to_json,
  "duplicates": [.. | select(tag == "!!map") | (keys | group_by(.) | .[] | select(length > 1) | .[0])],
  "key_tags": [.. | select(kind == "map") | keys | .[] | tag],
  "tags": [... | tag],
  "comments": [... | [head_comment, line_comment, foot_comment] | .[] | select(. != "")]
}]]
local safe_tags =
	{ "!!map", "!!seq", "!!str", "!!int", "!!float", "!!bool", "!!null", "!!timestamp", "!!binary", "!!merge", "" }

local function run(expression, text, format, env)
	local version, err = M.check_yq()
	if not version then
		return nil, err
	end
	return execute({
		require("aero.config").options.tasks.yq,
		"eval",
		"--input-format=yaml",
		"--output-format=" .. format,
		"--no-colors",
		"--no-doc",
		expression,
		"-",
	}, { stdin = text, text = true, env = env })
end

local function comment_lines(comments)
	local lines = {}
	for _, comment in ipairs(comments or {}) do
		for _, line in ipairs(vim.split(comment, "\n", { plain = true })) do
			table.insert(lines, line)
		end
	end
	return lines
end

local function date(value, timestamp)
	if type(value) ~= "string" then
		return false
	end
	local y, m, d = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
	if timestamp then
		local h, min, sec
		y, m, d, h, min, sec = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
		if not h or tonumber(h) > 23 or tonumber(min) > 59 or tonumber(sec) > 59 then
			return false
		end
	end
	if not y then
		return false
	end
	y, m, d = tonumber(y), tonumber(m), tonumber(d)
	local days =
		{ 31, (y % 4 == 0 and (y % 100 ~= 0 or y % 400 == 0)) and 29 or 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	return y > 0 and m >= 1 and m <= 12 and d >= 1 and d <= days[m]
end

function M.validate(data, kind)
	local errors = {}
	local function check(ok, message)
		if not ok then
			table.insert(errors, message)
		end
	end
	check(data.aero_type == kind, "aero_type must be " .. kind)
	check(data.schema_version == 1, "unsupported schema_version (expected 1)")
	for _, field in ipairs({ "id", "title" }) do
		check(
			type(data[field]) == "string" and vim.trim(data[field]) ~= "" and not data[field]:find("%c"),
			field .. " must be a nonempty single-line string"
		)
	end
	for _, field in ipairs({ "created_at", "updated_at" }) do
		if data[field] ~= nil then
			check(date(data[field], true), field .. " must be a UTC ISO 8601 timestamp")
		end
	end
	for _, field in ipairs({ "tags", "assignees" }) do
		if data[field] ~= nil then
			local valid = type(data[field]) == "table" and vim.islist(data[field])
			if valid then
				for _, value in ipairs(data[field]) do
					valid = valid and type(value) == "string"
				end
			end
			check(valid, field .. " must be a list of strings")
		end
	end
	if data.archived ~= nil then
		check(type(data.archived) == "boolean", "archived must be boolean")
	end
	if data.description ~= nil then
		check(type(data.description) == "string", "description must be a string")
	end
	if kind == "ticket" and data.state ~= nil then
		check(
			type(data.state) == "string" and vim.trim(data.state) ~= "" and not data.state:find("%c"),
			"state must be a nonempty single-line string"
		)
	end
	if data.priority ~= nil then
		check(vim.tbl_contains({ "low", "normal", "high", "urgent" }, data.priority), "invalid priority")
	end
	if data.due_date ~= nil then
		check(date(data.due_date), "due_date must be YYYY-MM-DD")
	end
	if data.estimate ~= nil then
		check(
			type(data.estimate) == "number" and data.estimate >= 0 and data.estimate < math.huge,
			"estimate must be a finite nonnegative number"
		)
	end
	return errors
end

function M.parse(lines, kind)
	if lines[1] ~= "---" then
		return nil, "missing leading YAML frontmatter"
	end
	local finish
	for i = 2, #lines do
		if lines[i] == "---" then
			finish = i
			break
		end
	end
	if not finish then
		return nil, "unterminated YAML frontmatter"
	end
	local text = table.concat(vim.list_slice(lines, 2, finish - 1), "\n") .. "\n"
	local cache_key = tostring(require("aero.config").options.tasks.yq) .. "\0" .. text
	local result = cache[cache_key]
	if not result then
		local output, err = run(inspect, text, "json")
		if not output then
			return nil, err
		end
		local decoded, value = pcall(vim.json.decode, output)
		if not decoded then
			return nil, "invalid or multiple YAML documents: " .. tostring(value)
		end
		result = value
		if result.kind ~= "map" then
			return nil, "frontmatter must be a YAML mapping"
		end
		if #result.duplicates > 0 then
			return nil, "duplicate YAML key: " .. table.concat(vim.tbl_map(tostring, result.duplicates), ", ")
		end
		for _, tag in ipairs(result.tags) do
			if not vim.tbl_contains(safe_tags, tag) then
				return nil, "unsupported YAML tag: " .. tag
			end
		end
		for _, tag in ipairs(result.key_tags) do
			if tag ~= "!!str" then
				return nil, "metadata mapping keys must be strings"
			end
		end
		local ok, data = pcall(vim.json.decode, result.data)
		if not ok then
			return nil, "invalid YAML data: " .. tostring(data)
		end
		result.data = data
		if vim.tbl_count(cache) > 256 then
			cache = {}
		end
		cache[cache_key] = result
	end
	local errors = M.validate(result.data, kind)
	return {
		data = vim.deepcopy(result.data),
		finish = finish,
		errors = errors,
		comments = result.comments,
		kind = kind,
	}
end

function M.edit(lines, document, changes)
	for field in pairs(changes) do
		assert(type(field) == "string" and field:match("^[%w_-]+$"), "invalid metadata field")
	end
	local text = table.concat(vim.list_slice(lines, 2, document.finish - 1), "\n") .. "\n"
	local expression = "(env(AERO_TASK_CHANGES) | to_entries | .[]) as $item ireduce (. ; .[$item.key] = $item.value)"
	local yaml, write_err = run(expression, text, "yaml", { AERO_TASK_CHANGES = vim.json.encode(changes) })
	assert(yaml, write_err)
	local out = { "---" }
	vim.list_extend(out, require("aero.tasks.storage").lines(yaml))
	vim.list_extend(out, vim.list_slice(lines, document.finish, #lines))
	local parsed, err = M.parse(out, document.kind)
	assert(parsed and #parsed.errors == 0, err or parsed and table.concat(parsed.errors, "; "))
	-- yq retains node comments, but replacement collections lose child comments.
	-- Keep every such comment as a standalone frontmatter comment, including duplicates.
	local remaining = {}
	for _, comment in ipairs(comment_lines(parsed.comments)) do
		remaining[comment] = (remaining[comment] or 0) + 1
	end
	local missing = {}
	for _, comment in ipairs(comment_lines(document.comments)) do
		if (remaining[comment] or 0) > 0 then
			remaining[comment] = remaining[comment] - 1
		else
			table.insert(missing, "# " .. comment)
		end
	end
	for i = #missing, 1, -1 do
		table.insert(out, 2, missing[i])
	end
	return out
end

return M
