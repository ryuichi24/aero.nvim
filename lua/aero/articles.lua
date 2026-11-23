-- Global article library and persistent per-session active document pointers.
local api = vim.api
local M = {}

function M.directory()
	return vim.fs.joinpath(vim.fn.stdpath("data"), "Aero", "articles")
end

local function prepare()
	local directory = M.directory()
	vim.fn.mkdir(directory, "p")
	local taxonomy = vim.fs.joinpath(directory, "taxonomy.json")

	if vim.fn.filereadable(taxonomy) == 0 then
		vim.fn.writefile({ '{"tags":[],"categories":[]}' }, taxonomy)
	end

	return directory, taxonomy
end

local function pointer(session)
	local key = tostring(session.key)
	return vim.fs.joinpath(M.directory(), ".session-" .. vim.fn.sha256(key) .. ".json")
end

local function identity(path)
	if vim.fn.filereadable(path) == 0 then
		return {}
	end

	local metadata = require("aero.tasks.frontmatter").parse(vim.fn.readfile(path), "article")
	return metadata and metadata.data or {}
end

function M.active(session)
	local path = pointer(session)

	if vim.fn.filereadable(path) == 0 then
		return
	end

	local ok, value = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))

	if not ok then
		return
	end

	local record = type(value) == "string" and { path = value } or value

	if
		type(record) ~= "table"
		or type(record.path) ~= "string"
		or vim.fs.dirname(record.path) ~= M.directory()
		or not record.path:match("%.mdx?$")
	then
		return
	end

	if vim.fn.filereadable(record.path) == 1 then
		M.activate(session, record.path, vim.tbl_extend("force", record, identity(record.path)))
		return record.path
	end

	local article_id, language = record.articleId, record.lang

	if not article_id then
		article_id, language =
			vim.fs.basename(record.path):match("^(%d%d%d%d%d%d%d%d%-%d%d%d%d%d%d%-%x+)%.([%w%-]+)%.mdx?$")
	end

	if article_id and language then
		local found

		for name, kind in vim.fs.dir(M.directory()) do
			if kind == "file" and name:match("%.mdx?$") then
				local candidate = vim.fs.joinpath(M.directory(), name)
				local data = identity(candidate)

				if data.articleId == article_id and data.lang == language then
					if found then
						return record.path
					end

					found = candidate
				end
			end
		end

		if found then
			M.activate(session, found)
			return found
		end
	end

	return record.path
end

function M.activate(session, path, metadata)
	prepare()
	metadata = metadata or identity(path)
	vim.fn.writefile(
		{ vim.json.encode({ path = path, articleId = metadata.articleId, lang = metadata.lang }) },
		pointer(session)
	)
end

function M.context(session, text)
	local command, argument = vim.trim(text):match("^(%S+)%s*(.-)$")
	local generate = command == "/to-article"
	local active = M.active(session)
	local options = require("aero.config").options.articles
	local format = argument ~= "" and argument or options.format
	local languages, seen = {}, {}

	if generate then
		if argument ~= "" and argument ~= "md" and argument ~= "mdx" then
			return nil, "use /to-article [md|mdx]"
		end

		if format ~= "md" and format ~= "mdx" then
			return nil, 'articles.format must be "md" or "mdx"'
		end

		if type(options.languages) ~= "table" or not vim.islist(options.languages) or #options.languages == 0 then
			return nil, "articles.languages must be a non-empty list of language codes"
		end

		for _, language in ipairs(options.languages) do
			if type(language) ~= "string" or not language:match("^[a-z][a-z]%-?[A-Za-z0-9%-]*$") then
				return nil, "articles.languages must contain language codes such as en, ja, or en-US"
			end

			local key = language:lower()

			if not seen[key] then
				seen[key] = true
				table.insert(languages, language)
			end
		end
	end

	if not generate and not active then
		return text
	end

	local directory, taxonomy = prepare()

	if generate then
		local article_id = os.date("%Y%m%d-%H%M%S-")
			.. vim.fn.sha256(pointer(session) .. tostring(vim.uv.hrtime())):sub(1, 10)
		local targets = {}

		for _, language in ipairs(languages) do
			table.insert(targets, {
				lang = language,
				path = vim.fs.joinpath(directory, article_id .. "." .. language .. "." .. format),
			})
		end

		active = targets[1].path
		M.activate(session, active, { articleId = article_id, lang = targets[1].lang })
		text = options.prompt
			.. "\n\nGenerate and save ALL language versions listed below, not just the active version. Write each language to its own target path. "
			.. "Do not ask the user to choose one language. After writing, rename each new file to <slug>.<lang>."
			.. format
			.. " in the same directory using its final frontmatter slug and lang. "
			.. "Never overwrite another article: if the destination exists, choose a distinct slug and update the frontmatter before renaming. Preserve articleId and lang when renaming. Report every final saved path. "
			.. "Write natural localized prose while preserving technical meaning, code examples, and conclusions across versions.\n"
			.. "Language targets: "
			.. vim.json.encode(targets)
			.. "\nShared articleId: "
			.. vim.json.encode(article_id)
			.. "\nEach file must have YAML frontmatter with the shared articleId, its target lang, a URL-safe lowercase ASCII hyphenated slug, "
			.. "a localized title and description, pubDate: "
			.. os.date("%Y-%m-%d")
			.. ", draft: true, tags (list), and category (string). Keep pubDate, canonical tags, and category consistent across languages. "
			.. "Preserve articleId, lang, pubDate, and slug during later revisions unless explicitly requested."

		if format == "mdx" then
			text = text
				.. "\nWrite valid MDX: use JSX-compatible markup, escape literal braces and angle brackets in prose, and keep code examples in fenced code blocks. Only use components with valid imports available in the target blog."
		end
	end

	return text
		.. "\n\n[Aero article context]\nActive article: "
		.. vim.json.encode(active)
		.. "\nGlobal taxonomy: "
		.. vim.json.encode(taxonomy)
		.. "\nFor article requests, read the active file before revising and update it in place unless a new article is requested. "
		.. "Keep existing filenames stable during revisions unless explicitly asked to rename. Preserve articleId and lang so Aero can track renamed files. "
		.. "Use YAML frontmatter with title (string), tags (list), and category (one string). "
		.. "Read the global taxonomy JSON (tags and categories arrays) before choosing metadata. Reuse semantically matching entries, avoiding spelling/case/plural variants. "
		.. "Add genuinely new entries to the taxonomy, preserving existing entries; reread it before writing. Persist the Markdown or MDX file locally."
end

function M.open(path)
	local win = require("aero.navigation").code_window("articles")
	api.nvim_set_current_win(win)
	vim.cmd.edit(vim.fn.fnameescape(path))
end

function M.pick(session)
	local directory = prepare()
	local choices = {}

	for name, kind in vim.fs.dir(directory) do
		if kind == "file" and name:match("%.mdx?$") then
			table.insert(choices, name)
		end
	end

	table.sort(choices)
	table.insert(choices, 1, "Open articles folder")
	vim.ui.select(choices, { prompt = "Articles" }, function(name)
		if not name then
			return
		end

		if name == "Open articles folder" then
			return M.open(directory)
		end

		local path = vim.fs.joinpath(directory, name)

		if session then
			M.activate(session, path)
		end

		M.open(path)
	end)
end

return M
