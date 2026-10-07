-- Worktree-relative path mentions in prompt drafts.
local M = {}

function M.items(root, callback)
	local function finish(result)
		vim.schedule(function()
			local paths = {}
			local function add(path)
				paths[path] = true
				for slash in path:gmatch("()/") do
					paths[path:sub(1, slash)] = true
				end
			end
			if result.code == 0 then
				for path in result.stdout:gmatch("[^%z]+") do
					add(path)
				end
			else
				local function scan(dir, prefix)
					for name, kind in vim.fs.dir(dir) do
						if name ~= ".git" then
							local path = prefix .. name
							add(path .. (kind == "directory" and "/" or ""))
							if kind == "directory" then
								scan(dir .. "/" .. name, path .. "/")
							end
						end
					end
				end
				scan(root, "")
			end
			local items = {}
			for path in pairs(paths) do
				items[#items + 1] = { key = path }
			end
			table.sort(items, function(a, b) return a.key < b.key end)
			callback(items)
		end)
	end
	vim.system({ "git", "ls-files", "-z", "--cached", "--others", "--exclude-standard" }, { cwd = root }, function(result)
		if result.code ~= 0 then
			finish(result)
			return
		end
		-- Include untracked directories, including empty folders.
		vim.system({ "git", "ls-files", "-z", "--others", "--exclude-standard", "--directory" }, { cwd = root }, function(dirs)
			if dirs.code == 0 then result.stdout = result.stdout .. dirs.stdout end
			finish(result)
		end)
	end)
end

function M.token(before)
	local start, query = before:match('()@([^%s@"]*)$')
	if start and (start == 1 or before:sub(start - 1, start - 1):match("[%s%(%[%{]")) then
		return start, query
	end
end

function M.candidates(items, query)
	local matches = query == "" and items or vim.fn.matchfuzzy(items, query, { key = "key" })
	local out = {}
	for _, item in ipairs(matches) do
		if not item.key:find("[%c]") then
			local path = item.key:find('[%s"]') and ('"' .. item.key:gsub("\\", "\\\\"):gsub('"', '\\"') .. '"') or item.key
			out[#out + 1] = {
				word = "@" .. path .. " ",
				abbr = item.key,
				menu = item.key:sub(-1) == "/" and "Folder" or "File",
				equal = 1, -- Already fuzzy-filtered; disable native prefix filtering.
			}
		end
	end
	return out
end

return M
