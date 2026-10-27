-- Statement spacing uses Neovim's bundled Lua Tree-sitter parser, not line patterns.
local M = {}

function M.format(source, opts)
	local test_file = opts and opts.test_file
	local parser = vim.treesitter.get_string_parser(source, "lua")
	local root = parser:parse()[1]:root()

	if root:has_error() then
		error("Lua parse error; refusing to change statement spacing")
	end

	local lines = vim.split(source, "\n", { plain = true })
	local boundaries = {}
	local removals = {}

	local function control(node)
		return node:type() == "if_statement" or node:type() == "for_statement"
	end

	local function call_name(node)
		if node:type() ~= "function_call" then
			return nil
		end

		local name = node:field("name")[1]
		return name and vim.treesitter.get_node_text(name, source)
	end

	local function test_boundary(previous, current)
		if not test_file then
			return false
		end

		local before, after = call_name(previous), call_name(current)
		return before == "check" or after == "check" or (before == "assert") ~= (after == "assert")
	end

	local function last_row(node)
		local _, _, row, column = node:range()
		return column == 0 and row - 1 or row
	end

	local function visit(node)
		if node:type() == "chunk" or node:type() == "block" then
			local previous
			local statement
			local commented = false

			for child in node:iter_children() do
				if child:type() == "comment" then
					commented = true

					-- A trailing long comment belongs to the preceding statement;
					-- never insert a blank line inside its contents.
					if previous and child:range() == last_row(previous) then
						previous = child
					end
				elseif child:named() and child:type() ~= "hash_bang_line" then
					if previous then
						local last = last_row(previous)
						local first = child:range()
						local blank = false

						for row = last + 1, first - 1 do
							if lines[row + 1]:match("^%s*$") then
								blank = true
								break
							end
						end

						if
							(control(statement) or control(child) or test_boundary(statement, child))
							and not blank
							and first > last
						then
							boundaries[last + 2] = true
						elseif
							not test_file
							and not control(statement)
							and not control(child)
							and not commented
							and statement:type() ~= "function_declaration"
							and child:type() ~= "function_declaration"
						then
							for row = last + 1, first - 1 do
								if lines[row + 1]:match("^%s*$") then
									removals[row + 1] = true
								end
							end
						end
					end

					previous = child
					statement = child
					commented = false
				end
			end
		end

		for child in node:iter_children() do
			visit(child)
		end
	end

	visit(root)
	local result = {}

	for index, line in ipairs(lines) do
		if boundaries[index] then
			table.insert(result, "")
		end

		if not removals[index] then
			table.insert(result, line)
		end
	end

	return table.concat(result, "\n")
end

-- Tests load the formatter without running the command-line entry point.
if ... == "module" then
	return M
end

local check = false
local paths = {}

for _, value in ipairs(arg) do
	if value == "--check" then
		check = true
	else
		table.insert(paths, value)
	end
end

local failed = false

for _, path in ipairs(paths) do
	local files = vim.fn.isdirectory(path) == 1 and vim.fn.globpath(path, "**/*.lua", false, true) or { path }

	for _, file in ipairs(files) do
		local ok, err = pcall(function()
			local lines = vim.fn.readfile(file, "b")
			local source = table.concat(lines, "\n")
			local normalized = file:gsub("\\", "/")
			local formatted =
				M.format(source, { test_file = normalized:match("^tests/") or normalized:match("/tests/") })

			if formatted ~= source then
				if check then
					io.stderr:write(file .. ": incorrect Lua if/for spacing (run make format-lua)\n")
					failed = true
				else
					vim.fn.writefile(vim.split(formatted, "\n", { plain = true }), file, "b")
				end
			end
		end)

		if not ok then
			io.stderr:write(file .. ": " .. tostring(err) .. "\n")
			failed = true
		end
	end
end

if failed then
	vim.cmd("cquit 1")
end
