vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
local original = vim.fn.stdpath
vim.fn.stdpath = function(kind)
	return kind == "data" and root or original(kind)
end
local articles = require("aero.articles")
local session = { key = "first" }
local other = { key = "second" }

assert(articles.context(session, "hello") == "hello")

local config = require("aero.config")
config.setup({ articles = { prompt = "Write a practical tutorial with runnable examples." } })
local request = articles.context(session, "/to-article")
local path = articles.active(session)

assert(path and request:find(path, 1, true))
assert(request:find("Write a practical tutorial with runnable examples.", 1, true))
assert(request:find("Use YAML frontmatter", 1, true))
assert(vim.fn.filereadable(articles.directory() .. "/taxonomy.json") == 1)
assert(articles.active(other) == nil)
assert(articles.context(session, "Revise the introduction"):find(path, 1, true))

session.name = "renamed"

assert(articles.active(session) == path)

articles.activate(other, path)

assert(articles.active(other) == path)

config.setup({ articles = { languages = { "en", "ja", "en" } } })
local multilingual = articles.context(session, "/to-article")
local targets = vim.json.decode(multilingual:match("Language targets: ([^\n]+)"))
local article_id = vim.json.decode(multilingual:match("Shared articleId: ([^\n]+)"))

assert(#targets == 2)
assert(targets[1].lang == "en" and targets[2].lang == "ja")
assert(targets[1].path == articles.directory() .. "/" .. article_id .. ".en.md")
assert(targets[2].path == articles.directory() .. "/" .. article_id .. ".ja.md")
assert(articles.active(session) == targets[1].path)
assert(multilingual:find("Generate and save ALL language versions", 1, true))
assert(multilingual:find("draft: true", 1, true))

articles.activate(session, targets[2].path)
local revision = articles.context(session, "Revise the introduction")

assert(revision:find(targets[2].path, 1, true))
assert(not revision:find("Language targets:", 1, true))

assert(multilingual:find("rename each new file to <slug>.<lang>.md", 1, true))

vim.fn.writefile(
	{ "---", "articleId: " .. article_id, "lang: ja", "slug: readable-post", "---", "Article" },
	targets[2].path
)
articles.activate(session, targets[2].path)
local renamed = articles.directory() .. "/readable-post.ja.md"

assert(vim.uv.fs_rename(targets[2].path, renamed))
assert(articles.active(session) == renamed)
assert(articles.context(session, "Revise"):find(renamed, 1, true))

-- The refreshed pointer also follows subsequent renames after reloading the module.
local renamed_again = articles.directory() .. "/another-slug.ja.md"

assert(vim.uv.fs_rename(renamed, renamed_again))

package.loaded["aero.articles"] = nil
articles = require("aero.articles")

assert(articles.active(session) == renamed_again)

local pointer = articles.directory() .. "/.session-" .. vim.fn.sha256(tostring(session.key)) .. ".json"
vim.fn.writefile({ vim.json.encode(targets[2].path) }, pointer)

assert(articles.active(session) == renamed_again)

local duplicate = articles.directory() .. "/duplicate.ja.md"
vim.fn.writefile(vim.fn.readfile(renamed_again), duplicate)
vim.fn.writefile({ vim.json.encode(targets[2].path) }, pointer)

assert(articles.active(session) == targets[2].path)

vim.fn.delete(duplicate)

assert(articles.active(session) == renamed_again)

config.setup({ articles = { languages = {} } })
local invalid, err = articles.context(session, "/to-article")

assert(invalid == nil and err:find("non%-empty"))
assert(articles.active(session) == renamed_again)

config.setup({ articles = { languages = { "../ja" } } })
invalid, err = articles.context(session, "/to-article")

assert(invalid == nil and err:find("language codes", 1, true))

config.setup({ articles = { format = "mdx", languages = { "en", "ja" } } })
local mdx = articles.context(session, "/to-article")
local mdx_targets = vim.json.decode(mdx:match("Language targets: ([^\n]+)"))

assert(mdx_targets[1].path:match("%.en%.mdx$"))
assert(mdx_targets[2].path:match("%.ja%.mdx$"))
assert(mdx:find("<slug>.<lang>.mdx", 1, true))
assert(mdx:find("Write valid MDX", 1, true))

vim.fn.writefile({ "---", "articleId: mdx-post", "lang: en", "---", "<Example />" }, mdx_targets[1].path)
articles.activate(session, mdx_targets[1].path)
local mdx_renamed = articles.directory() .. "/mdx-post.en.mdx"

assert(vim.uv.fs_rename(mdx_targets[1].path, mdx_renamed))
assert(articles.active(session) == mdx_renamed)
assert(articles.context(session, "Revise"):find(mdx_renamed, 1, true))

local select = vim.ui.select
local choices
vim.ui.select = function(items)
	choices = items
end
articles.pick(session)
vim.ui.select = select

assert(vim.tbl_contains(choices, "mdx-post.en.mdx"))

config.setup({ articles = { format = "html" } })
invalid, err = articles.context(session, "/to-article")

assert(invalid == nil and err:find("articles.format", 1, true))
assert(articles.active(session) == mdx_renamed)

config.setup({ articles = { format = "md", languages = { "en", "ja" } } })
local override = articles.context(session, "/to-article mdx")
local override_targets = vim.json.decode(override:match("Language targets: ([^\n]+)"))

assert(override_targets[1].path:match("%.en%.mdx$"))
assert(override_targets[2].path:match("%.ja%.mdx$"))
assert(override:find("Write valid MDX", 1, true))
assert(config.options.articles.format == "md")

config.setup({ articles = { format = "mdx" } })
override = articles.context(session, "/to-article md")
override_targets = vim.json.decode(override:match("Language targets: ([^\n]+)"))

assert(override_targets[1].path:match("%.en%.md$"))
assert(not override:find("Write valid MDX", 1, true))
assert(config.options.articles.format == "mdx")

local previous = articles.active(session)

for _, command in ipairs({ "/to-article html", "/to-article mdx extra" }) do
	invalid, err = articles.context(session, command)

	assert(invalid == nil and err == "use /to-article [md|mdx]")
	assert(articles.active(session) == previous)
end

vim.fn.stdpath = original
vim.fn.delete(root, "rf")
print("article context and persistence checks passed")
