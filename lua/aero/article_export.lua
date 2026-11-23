-- Group the global library by stable identity and export through the shared staging UI.
local M = {}

local function segment(value)
	return type(value) == "string"
		and value:match("^[a-z0-9]+[a-z0-9%-]*$")
		and not value:find("%-%-")
		and not value:match("%-$")
end

function M.groups()
	local directory = require("aero.articles").directory()
	local groups = {}

	if vim.fn.isdirectory(directory) == 0 then
		return {}
	end

	for name, kind in vim.fs.dir(directory) do
		if kind == "file" and name:match("%.mdx?$") then
			local path = vim.fs.joinpath(directory, name)
			local parsed, err = require("aero.tasks.frontmatter").parse(vim.fn.readfile(path), "article")
			local data = parsed and parsed.data

			if not data or not segment(data.articleId) or not segment(data.lang) then
				return nil, name .. ": " .. (err or "requires articleId and lang metadata")
			end

			local group = groups[data.articleId] or { id = data.articleId, versions = {} }

			if group.versions[data.lang] then
				return nil, "duplicate language for " .. data.articleId .. ": " .. data.lang
			end

			group.versions[data.lang] = { path = path, data = data }
			groups[group.id] = group
		end
	end

	local result = {}

	for _, group in pairs(groups) do
		local languages = vim.tbl_keys(group.versions)
		table.sort(languages)
		local preferred = languages[1]

		for _, language in ipairs(require("aero.config").options.articles.languages) do
			if group.versions[language] then
				preferred = language
				break
			end
		end

		group.path = group.id
		group.name = (group.versions[preferred].data.title or group.id)
			.. " ["
			.. table.concat(languages, ", ")
			.. "] · "
			.. group.id
		table.insert(result, group)
	end

	table.sort(result, function(a, b)
		return a.name < b.name
	end)
	return result
end

function M.transfer(directory, groups, items)
	local plan, conflicts, destinations = {}, {}, {}

	for _, item in ipairs(items) do
		local group = groups[item.path]

		if not group then
			return nil, "unknown article: " .. item.path
		end

		for language, version in pairs(group.versions) do
			local source_buf = vim.fn.bufnr(version.path)

			if source_buf ~= -1 and vim.bo[source_buf].modified then
				return nil, "save article buffer before exporting: " .. version.path
			end

			local source = vim.fn.readfile(version.path, "b")
			local parsed = require("aero.tasks.frontmatter").parse(source, "article")

			if not parsed or parsed.data.articleId ~= group.id or parsed.data.lang ~= language then
				return nil, "article identity changed; reopen the export finder: " .. version.path
			end

			if not segment(parsed.data.slug) then
				return nil, "article requires a URL-safe slug: " .. version.path
			end

			local extension = version.path:match("%.(mdx?)$")
			local destination = vim.fs.joinpath(directory, parsed.data.slug, language .. "." .. extension)

			if destinations[destination] then
				return nil, "multiple articles target the same destination: " .. destination
			end

			destinations[destination] = true
			local parent = vim.fs.dirname(destination)

			if vim.uv.fs_lstat(parent) and vim.uv.fs_lstat(parent).type ~= "directory" then
				return nil, "destination is not a regular directory: " .. parent
			end

			local stat = vim.uv.fs_lstat(destination)

			if stat and stat.type ~= "file" then
				return nil, "destination is not a regular file: " .. destination
			end

			local existing = stat and vim.fn.readfile(destination, "b")

			if not existing or not vim.deep_equal(source, existing) then
				table.insert(plan, { path = destination, lines = source, existing = existing })

				if existing then
					table.insert(conflicts, destination)
				end
			end
		end
	end

	if
		#conflicts > 0
		and vim.fn.confirm(
				"Replace differing exported files?\n" .. table.concat(conflicts, "\n"),
				"&Replace\n&Cancel",
				2
			)
			~= 1
	then
		return nil, "export cancelled; staged articles retained"
	end

	for _, entry in ipairs(plan) do
		local buf = vim.fn.bufnr(entry.path)

		if buf ~= -1 and vim.bo[buf].modified then
			return nil, "save destination buffer before exporting: " .. entry.path
		end

		local exists = vim.uv.fs_lstat(entry.path)

		if
			(exists and exists.type ~= "file")
			or not vim.deep_equal(exists and vim.fn.readfile(entry.path, "b") or nil, entry.existing)
		then
			return nil, "destination changed; retry export: " .. entry.path
		end
	end

	for _, entry in ipairs(plan) do
		local ok, err = require("aero.atomic_file").write(entry.path, table.concat(entry.lines, "\n"))

		if not ok then
			return nil, "cannot write " .. entry.path .. ": " .. tostring(err)
		end
	end

	if #items > 0 then
		vim.cmd("checktime")
		vim.notify("Aero: exported " .. #items .. " article(s), wrote " .. #plan .. " file(s) to " .. directory)
	end

	return true
end

function M.command(args)
	local function warn(message)
		vim.notify("Aero: " .. message, vim.log.levels.WARN)
	end

	if #args ~= 1 or args[1] ~= "export" then
		return warn("use :Aero article export")
	end

	local directory = require("aero.config").options.articles.export.directory

	if type(directory) ~= "string" or vim.trim(directory) == "" then
		return warn("set articles.export.directory to your blog's content directory")
	end

	directory = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(directory), ":p"))
	local entries, err = M.groups()

	if not entries then
		return warn(err)
	end

	if #entries == 0 then
		return warn("no articles available to export")
	end

	local groups = {}

	for _, entry in ipairs(entries) do
		groups[entry.id] = entry
	end

	return require("aero.file_finder").open({
		home = require("aero.articles").directory(),
		entries = entries,
		copy_only = true,
		target_key = "article-export:" .. directory,
		target_label = "Blog",
		target_path = directory,
		target_kind = "Destination",
		title = "Export articles",
		stack_title = "Staged articles",
		filetype = "aero_article_export",
		empty_hint = "  y: mark articles (visual supported) · u: unmark/unstage · :w: stage · q/Esc: export staged",
		label = function(id)
			return groups[id].name:gsub("[%c]", " ")
		end,
		transfer = function(items)
			return M.transfer(directory, groups, items)
		end,
	})
end

return M
