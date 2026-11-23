vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
local library = root .. "/library"
local destination = root .. "/posts"
vim.fn.mkdir(library, "p")
require("aero.config").setup({ articles = { languages = { "ja", "en" }, export = { directory = destination } } })
require("aero.articles").directory = function()
	return library
end

for _, language in ipairs({ "en", "ja" }) do
	vim.fn.writefile({
		"---",
		"articleId: example",
		"lang: " .. language,
		"slug: readable-" .. language,
		"title: Title " .. language,
		"draft: true",
		"---",
		"Body",
	}, library .. "/example." .. language .. ".md")
end

local exporter = require("aero.article_export")
local groups = assert(exporter.groups())

assert(#groups == 1 and groups[1].name:find("Title ja", 1, true))

vim.fn.writefile(
	{ "---", "articleId: second", "lang: en", "slug: another-post", "title: Zebra", "---", "Second body" },
	library .. "/second.en.md"
)

local finder = exporter.command({ "export" })

assert(#finder.entries == 2)
assert(vim.fn.maparg("d", "n") == "")

local function key(value)
	local mapping = vim.fn.maparg(value, "n", false, true)
	mapping.callback()
end

key("y")

assert(finder.pending.example == "copy" and #finder.staged == 0)

vim.api.nvim_win_set_cursor(finder.win, { 2, 0 })
key("y")
key("u")

assert(not finder.pending.second)

key("y")

vim.cmd.write()

assert(#finder.staged == 2)

key("q")

assert(vim.fn.filereadable(destination .. "/readable-en/en.md") == 1)
assert(vim.fn.filereadable(destination .. "/readable-ja/ja.md") == 1)
assert(vim.fn.filereadable(destination .. "/another-post/en.md") == 1)
assert(vim.fn.isdirectory(destination .. "/example") == 0)
assert(vim.fn.filereadable(library .. "/example.en.md") == 1)

local confirm = vim.fn.confirm
vim.fn.writefile({ "Changed" }, destination .. "/readable-en/en.md")
vim.fn.confirm = function()
	return 2
end
local ok = exporter.transfer(destination, { example = groups[1] }, { { path = "example" } })

assert(not ok)
assert(vim.fn.readfile(destination .. "/readable-en/en.md")[1] == "Changed")

vim.fn.confirm = function()
	return 1
end

assert(exporter.transfer(destination, { example = groups[1] }, { { path = "example" } }))
assert(
	vim.deep_equal(vim.fn.readfile(destination .. "/readable-en/en.md"), vim.fn.readfile(library .. "/example.en.md"))
)

vim.fn.confirm = confirm

assert(vim.uv.fs_rename(library .. "/example.en.md", library .. "/example.en.mdx"))

groups = assert(exporter.groups())
local example

for _, group in ipairs(groups) do
	if group.id == "example" then
		example = group
	end
end

assert(example and example.versions.en.path:match("%.mdx$"))
assert(exporter.transfer(destination, { example = example }, { { path = "example" } }))
assert(vim.fn.filereadable(destination .. "/readable-en/en.mdx") == 1)
assert(
	vim.deep_equal(vim.fn.readfile(destination .. "/readable-en/en.mdx"), vim.fn.readfile(library .. "/example.en.mdx"))
)

vim.fn.delete(root, "rf")
print("article export: OK")
