-- New task document construction; parsing and source-preserving edits remain in
-- markdown/frontmatter. Title and timestamp rules are shared by mutation planners.
local fm = require("aero.tasks.frontmatter")
local storage = require("aero.tasks.storage")
local M = {}

function M.now()
	return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

function M.title(value)
	return type(value) == "string" and vim.trim(value) ~= "" and not value:find("%c")
end

function M.create(kind, name, id, options, body)
	for field in pairs(options or {}) do
		if type(field) ~= "string" or not field:match("^[%w_-]+$") then
			return nil, "invalid metadata field"
		end
	end

	local data = vim.tbl_extend("force", options or {}, {
		aero_type = kind,
		schema_version = 1,
		id = id,
		title = name,
		created_at = M.now(),
		updated_at = M.now(),
	})

	if kind == "ticket" and data.task_type == nil then
		data.task_type = "general"
	end

	local errors = fm.validate(data, kind)

	if #errors > 0 then
		return nil, table.concat(errors, "; ")
	end

	local lines = { "---" }

	for _, field in ipairs(vim.tbl_keys(data)) do
		table.insert(lines, field .. ": " .. vim.json.encode(data[field]))
	end

	vim.list_extend(lines, { "---", "", "# " .. name, "" })
	vim.list_extend(lines, body or {})
	return storage.text(lines)
end

return M
