-- User-owned JSON snippets, merged by name with workspace entries taking priority.
local M = {}
local api = vim.api

local function scope_paths(directory, scope)
	local sources = {}
	local folder = vim.fs.joinpath(directory, "prompt")
	local scan, err, code = vim.uv.fs_scandir(folder)
	if not scan then
		return sources, code ~= "ENOENT" and { folder .. ": " .. err } or {}
	end
	local files = {}
	while true do
		local name, kind = vim.uv.fs_scandir_next(scan)
		if not name then break end
		if (kind == "file" or kind == "link") and (name:match("%.json$") or name:match("%.jsonc$")) then
			files[name] = true
		end
	end
	local names = {}
	for name in pairs(files) do
		-- Prefer JSONC when both extensions exist for the same basename.
		if not (name:match("%.json$") and files[name .. "c"]) then table.insert(names, name) end
	end
	table.sort(names)
	for _, name in ipairs(names) do
		table.insert(sources, { path = vim.fs.joinpath(folder, name), scope = scope })
	end
	return sources, {}
end

function M.global_paths(directory)
	return scope_paths(directory, "global")
end

function M.paths(worktree)
	local root = require("aero.git").main_root(worktree) or worktree
	local sources, errors = M.global_paths(vim.fs.joinpath(vim.fn.stdpath("config"), "aero"))
	local workspace_sources, workspace_errors = scope_paths(vim.fs.joinpath(root, ".aero"), "workspace")
	vim.list_extend(sources, workspace_sources)
	vim.list_extend(errors, workspace_errors)
	return sources, errors
end

local function read(path)
	local stat, err, code = vim.uv.fs_stat(path)
	if not stat then
		return code == "ENOENT" and {} or nil, err
	end
	local ok, data = pcall(function()
		return require("aero.jsonc").decode(table.concat(vim.fn.readfile(path), "\n"))
	end)
	if not ok then return nil, tostring(data) end
	if type(data) ~= "table" or not vim.islist(data) then
		return nil, "expected a JSON array of snippets"
	end
	local names = {}
	for index, item in ipairs(data) do
		if type(item) ~= "table" or type(item.name) ~= "string" or vim.trim(item.name) == ""
			or type(item.prompt) ~= "string" or vim.trim(item.prompt) == ""
			or (item.description ~= nil and type(item.description) ~= "string") then
			return nil, "snippet " .. index .. " requires non-empty name and prompt strings and an optional description string"
		end
		if names[item.name] then return nil, "duplicate snippet name: " .. item.name end
		names[item.name] = true
	end
	return data
end

function M.list(worktree)
	local sources, errors = M.paths(worktree)
	local merged = {}
	errors = errors or {}
	for _, source in ipairs(sources) do
		local items, err = read(source.path)
		if not items then
			table.insert(errors, source.path .. ": " .. err)
		else
			for _, item in ipairs(items) do
				merged[item.name] = {
					key = item.name, name = item.name, prompt = item.prompt,
					description = item.description or "", scope = source.scope,
				}
			end
		end
	end
	local items = vim.tbl_values(merged)
	table.sort(items, function(a, b) return a.name < b.name end)
	return items, errors
end

local variable_pattern = "{{%s*([%a_][%w_]*)%s*}}"

local function git(worktree, args)
	local command = { "git", "-C", worktree }
	vim.list_extend(command, args)
	local ok, result = pcall(function()
		return vim.system(command, { text = true }):wait(2000)
	end)
	return ok and result.code == 0 and (result.stdout or ""):gsub("\n$", "") or ""
end

local function source_context()
	local result = { file = "", filetype = "", selection = "", diagnostics = "" }
	local win = require("aero.buffers").code_win()
	if not win then return result end
	local buf = api.nvim_win_get_buf(win)
	if vim.bo[buf].buftype ~= "" then return result end
	result.file = api.nvim_buf_get_name(buf)
	result.filetype = vim.bo[buf].filetype
	-- Visual marks belong to the source buffer, not the composer or picker.
	local first, last = api.nvim_buf_get_mark(buf, "<"), api.nvim_buf_get_mark(buf, ">")
	if first[1] > 0 and last[1] > 0 then
		local ok, lines = pcall(vim.fn.getregion,
			{ buf, first[1], first[2] + 1, 0 }, { buf, last[1], last[2] + 1, 0 },
			{ type = vim.fn.visualmode() ~= "" and vim.fn.visualmode() or "v" })
		if ok then result.selection = table.concat(lines, "\n") end
	end
	local diagnostics = vim.diagnostic.get(buf)
	table.sort(diagnostics, function(a, b)
		if a.lnum ~= b.lnum then return a.lnum < b.lnum end
		return a.col < b.col
	end)
	local lines = {}
	for _, diagnostic in ipairs(diagnostics) do
		table.insert(lines, ("%s:%d:%d: %s: %s"):format(result.file,
			diagnostic.lnum + 1, diagnostic.col + 1,
			vim.diagnostic.severity[diagnostic.severity] or "UNKNOWN", diagnostic.message))
	end
	result.diagnostics = table.concat(lines, "\n")
	return result
end

function M.context(chat, template)
	local workspace = require("aero.git").main_root(chat.s.worktree) or chat.s.worktree
	local values = {
		workspace = workspace,
		worktree = chat.s.worktree,
		workspace_name = vim.fs.basename(workspace),
		worktree_name = vim.fs.basename(chat.s.worktree),
		session = chat.s.name,
		cwd = vim.fn.getcwd(),
		date = os.date("%Y-%m-%d"),
		time = os.date("%H:%M:%S"),
	}
	-- Avoid running Git for templates that do not need it.
	local needed = {}
	for name in (template or "{{branch}} {{diff}}"):gmatch(variable_pattern) do needed[name] = true end
	values.branch = needed.branch and git(chat.s.worktree, { "branch", "--show-current" }) or ""
	values.diff = needed.diff and git(chat.s.worktree, { "diff", "--no-ext-diff", "--no-color", "HEAD", "--" }) or ""
	return vim.tbl_extend("force", values, source_context())
end

-- A function replacement preserves percent signs and never expands inserted values again.
function M.render(template, values)
	return (template:gsub(variable_pattern, function(name)
		return values[name]
	end))
end

function M.expand(template, context, callback)
	local values, pending, seen = vim.deepcopy(context), {}, {}
	for name in template:gmatch(variable_pattern) do
		if values[name] == nil and not seen[name] then
			seen[name] = true
			table.insert(pending, name)
		end
	end
	local function next_variable(index)
		local name = pending[index]
		if not name then return callback(M.render(template, values)) end
		vim.ui.input({ prompt = "Aero prompt · " .. name .. ": " }, function(value)
			if value == nil then return callback(nil) end
			values[name] = value
			next_variable(index + 1)
		end)
	end
	next_variable(1)
end

function M.open(chat)
	local items, errors = M.list(chat.s.worktree)
	local templates = {}
	for _, item in ipairs(items) do table.insert(templates, item.prompt) end
	local context = M.context(chat, table.concat(templates, "\n"))
	for _, err in ipairs(errors) do vim.notify("Aero: " .. err, vim.log.levels.WARN) end
	require("aero.picker").open({
		title = "prompt snippets",
		items = function() return items end,
		label = function(item)
			return ("  %s [%s] %s"):format(item.name, item.scope, item.description)
		end,
		search = function(item) return item.name .. " " .. item.description .. " " .. item.prompt end,
		preview = function(item) return M.render(item.prompt, context) end,
		select = function(item)
			M.expand(item.prompt, context, function(expanded)
				if not expanded then return end
				if chat.s.chat ~= chat or not api.nvim_buf_is_valid(chat.buf) then
					vim.notify("Aero: conversation is no longer available", vim.log.levels.INFO)
					return
				end
				local buf = chat:get_prompt_buf()
				local draft = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
				local text = vim.trim(draft) == "/prompt" and expanded
					or (vim.trim(draft) == "" and expanded or draft .. "\n\n" .. expanded)
				api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
				chat:compose()
				api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(buf), 0 })
				vim.cmd.startinsert({ bang = true })
			end)
		end,
	})
end

return M
