-- Run: nvim --headless -u NONE -l tests/prompt_snippets.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/.aero", "p")
require("aero").setup({ state_file = dir .. "/state.json", animation = false })
local snippets = require("aero.prompt_snippets")
local decode = require("aero.jsonc").decode
local commented = [=[
// Snippet collection
[
  { /* inline block */
    "name": "Comments", // inline comment
    "prompt": "https://example.com /* literal */ // literal, } \\\"quoted\\\"",
  }, /* trailing comma and multiline
        comment */
]
]=]
local parsed = decode(commented)

assert(#parsed == 1 and parsed[1].name == "Comments")
assert(parsed[1].prompt == vim.json.decode('"https://example.com /* literal */ // literal, } \\\\\\"quoted\\\\\\""'))
assert(decode('["comma, ]", "comma, }",]')[1] == "comma, ]")
assert(not pcall(decode, "[ /* unfinished"))
assert(not pcall(decode, "[1 /* separation */ 2]"))
assert(not pcall(decode, "[1,,]"))
assert(not pcall(decode, "[,]"))
assert(not pcall(decode, "{,}"))

-- Isolate user-owned files from the machine running the test.
local original_paths = snippets.paths
local global_dir = dir .. "/global"
vim.fn.mkdir(global_dir .. "/prompt/nested", "p")

local function write_snippet(file, name, prompt)
	vim.fn.writefile({ vim.json.encode({ { name = name, prompt = prompt } }) }, file)
end

write_snippet(global_dir .. "/prompts.json", "Legacy", "ignored")
write_snippet(global_dir .. "/prompts.jsonc", "Legacy JSONC", "ignored")
write_snippet(global_dir .. "/prompt/10-review.json", "Shared", "first")
write_snippet(global_dir .. "/prompt/20-review.json", "Shared", "ignored JSON counterpart")
vim.fn.writefile(
	{ '[{"name":"Shared","prompt":"JSONC winner",},] // comment' },
	global_dir .. "/prompt/20-review.jsonc"
)
write_snippet(global_dir .. "/prompt/30-explain.json", "Explain", "explanation")
write_snippet(global_dir .. "/prompt/nested/ignored.json", "Nested", "ignored")
vim.fn.writefile({ "ignored" }, global_dir .. "/prompt/README.md")
local sources, source_errors = snippets.global_paths(global_dir)

assert(#sources == 3 and #source_errors == 0)
assert(sources[1].path == global_dir .. "/prompt/10-review.json")
assert(sources[2].path == global_dir .. "/prompt/20-review.jsonc")

snippets.paths = function()
	return snippets.global_paths(global_dir)
end
local combined, combined_errors = snippets.list(dir)

assert(#combined == 2 and #combined_errors == 0)
assert(combined[2].name == "Shared" and combined[2].prompt == "JSONC winner")

-- Invalid files do not prevent other global files from loading.
vim.fn.writefile({ "invalid" }, global_dir .. "/prompt/40-invalid.jsonc")
combined, combined_errors = snippets.list(dir)

assert(#combined == 2 and #combined_errors == 1)
assert(combined_errors[1]:find("40-invalid.jsonc", 1, true))

write_snippet(dir .. "/.aero/prompts.json", "Legacy workspace", "ignored")
write_snippet(dir .. "/.aero/prompts.jsonc", "Legacy workspace JSONC", "ignored")

-- Exercise real workspace discovery with an isolated global collection.
local original_global_paths = snippets.global_paths
snippets.global_paths = function()
	return original_global_paths(global_dir)
end
snippets.paths = original_paths
vim.fn.mkdir(dir .. "/.aero/prompt/nested", "p")
write_snippet(dir .. "/.aero/prompt/10-review.json", "Shared", "workspace first")
write_snippet(dir .. "/.aero/prompt/20-review.json", "Shared", "ignored counterpart")
vim.fn.writefile(
	{ '[{"name":"Shared","prompt":"workspace folder winner",},] // comment' },
	dir .. "/.aero/prompt/20-review.jsonc"
)
write_snippet(dir .. "/.aero/prompt/30-extra.json", "Workspace only", "extra")
write_snippet(dir .. "/.aero/prompt/nested/ignored.json", "Nested", "ignored")
vim.fn.writefile({ "invalid" }, dir .. "/.aero/prompt/40-invalid.jsonc")
combined, combined_errors = snippets.list(dir)

assert(#combined == 3 and #combined_errors == 2)
assert(combined[2].prompt == "workspace folder winner" and combined[2].scope == "workspace")
assert(combined[3].name == "Workspace only" and combined[3].scope == "workspace")

-- Folder files are rediscovered on every load.
vim.fn.delete(dir .. "/.aero/prompt/20-review.jsonc")
combined = snippets.list(dir)

assert(combined[2].prompt == "ignored counterpart")

snippets.global_paths = original_global_paths
vim.fn.delete(dir .. "/.aero/prompt", "rf")
vim.fn.delete(dir .. "/.aero/prompts.json")
vim.fn.delete(dir .. "/.aero/prompts.jsonc")
snippets.paths = original_paths
snippets.paths = function()
	return {
		{ path = dir .. "/global.json", scope = "global" },
		{ path = dir .. "/.aero/prompts.json", scope = "workspace" },
	}
end

local function write(path, data)
	vim.fn.writefile({ vim.json.encode(data) }, path)
end

assert(#snippets.list(dir) == 0)

vim.fn.writefile(vim.split(commented, "\n", { plain = true }), dir .. "/global.json")
local loaded, load_errors = snippets.list(dir)

assert(#loaded == 1 and #load_errors == 0 and loaded[1].prompt == parsed[1].prompt)

write(dir .. "/global.json", {
	{ name = "Review", prompt = "Global review" },
	{ name = "Explain", description = "Explain code", prompt = { "Explain this code.", "Include examples." } },
})
write(dir .. "/.aero/prompts.json", { { name = "Review", prompt = "Workspace review" } })
local items, errors = snippets.list(dir)

assert(#items == 2 and #errors == 0)
assert(items[2].prompt == "Workspace review" and items[2].scope == "workspace")

vim.fn.writefile({ "invalid JSON" }, dir .. "/.aero/prompts.json")
items, errors = snippets.list(dir)

assert(#items == 2 and #errors == 1 and items[2].scope == "global")

write(dir .. "/.aero/prompts.json", { { name = "broken" } })

assert(#select(2, snippets.list(dir)) == 1)

write(dir .. "/.aero/prompts.json", {
	{ name = "Review", prompt = { "  Review {{session}}", "", "Keep 100% of {{topic}}.", "" } },
})
items, errors = snippets.list(dir)

assert(#errors == 0 and items[2].scope == "workspace")
assert(items[2].prompt == "  Review {{session}}\n\nKeep 100% of {{topic}}.\n")
assert(
	snippets.render(items[2].prompt, { session = "test", topic = "code" }) == "  Review test\n\nKeep 100% of code.\n"
)

for _, invalid in ipairs({ {}, { "", "  " }, { "valid", 1 }, { "valid", vim.NIL }, { line = "text" } }) do
	write(dir .. "/.aero/prompts.json", { { name = "Review", prompt = invalid } })
	items, errors = snippets.list(dir)

	assert(#errors == 1 and items[2].scope == "global", "accepted invalid prompt: " .. vim.inspect(invalid))
end

write(dir .. "/.aero/prompts.json", {})
local chat = { s = { worktree = dir, name = "test", key = "snippet-test" }, buf = api.nvim_create_buf(false, true) }
chat.s.chat = chat
local draft_saves = 0

function chat:save_history()
	draft_saves = draft_saves + 1
end

function chat:get_prompt_buf()
	return require("aero.acp.prompt").buffer(self, function()
		return self
	end)
end

function chat:compose()
	api.nvim_set_current_buf(self:get_prompt_buf())
end

local buf = chat:get_prompt_buf()
chat:compose()
local submitted = 0

function chat:send_prompt_buf()
	submitted = submitted + 1
end

api.nvim_buf_set_lines(buf, 0, -1, false, { "Unfinished draft" })

assert(
	draft_saves > 0 and vim.deep_equal(chat.draft, { "Unfinished draft" }),
	"editing the prompt did not request draft persistence"
)

vim.fn.maparg("<CR>", "n", false, true).callback()
api.nvim_exec_autocmds("BufWriteCmd", { buffer = buf })

assert(submitted == 0, "Enter or :w submitted an unfinished draft")
assert(vim.fn.maparg("<C-s>", "i", false, true).desc ~= "Aero: send prompt")

for _, mode in ipairs({ "n", "i" }) do
	vim.fn.maparg("<C-CR>", mode, false, true).callback()
end

assert(submitted == 2, "Ctrl-Enter did not submit in both modes")

api.nvim_buf_set_lines(buf, 0, -1, false, { "/prompt" })

-- Sending opens the picker without clearing the command; closing preserves it.
require("aero.acp.prompt").send(chat)
require("aero.picker").close()

assert(api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "/prompt")

require("aero.acp.prompt").send(chat)
local search = api.nvim_get_current_buf()
api.nvim_buf_set_lines(search, 0, -1, false, { "examples" })
api.nvim_exec_autocmds("TextChanged", { buffer = search })
vim.fn.maparg("<CR>", "n", false, true).callback()

assert(api.nvim_get_current_buf() == buf)
assert(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") == "Explain this code.\nInclude examples.")

-- Reopening reloads files and appends to an existing draft.
write(dir .. "/global.json", { { name = "Updated", prompt = "Fresh text" } })
snippets.open(chat)
vim.fn.maparg("<CR>", "n", false, true).callback()

assert(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):match("\n\nFresh text$"))

-- A slash command on its own line extends an existing draft without sending it.
for _ = 1, 2 do
	local draft = api.nvim_buf_get_lines(buf, 0, -1, false)
	api.nvim_buf_set_lines(buf, -1, -1, false, { "/prompt" })
	api.nvim_win_set_cursor(0, { #draft + 1, 0 })
	require("aero.acp.prompt").send(chat)
	vim.fn.maparg("<CR>", "n", false, true).callback()

	assert(
		table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") == table.concat(draft, "\n") .. "\n\nFresh text"
	)
end

local reports = require("aero.reports")
local original_pick, picked = reports.pick, false
reports.pick = function(session)
	picked = session == chat.s
end
api.nvim_buf_set_lines(buf, 0, -1, false, { "Existing draft", "/report", "More context" })
api.nvim_win_set_cursor(0, { 2, 0 })
require("aero.acp.prompt").send(chat)
reports.pick = original_pick

assert(picked)
assert(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") == "Existing draft\nMore context")

local context = snippets.context(chat)

assert(context.worktree == dir and context.workspace == dir and context.session == "test")
assert(context.date:match("^%d%d%d%d%-%d%d%-%d%d$") and context.time:match("^%d%d:%d%d:%d%d$"))
assert(snippets.render("{{ session }} {{unknown}}", context) == "test {{unknown}}")

local result
local completion = require("aero.acp.completion")
local original_setup, variable_candidates = completion.setup
completion.setup = function(input, root, candidates)
	variable_candidates = candidates
	original_setup(input, root, candidates)
end

local function answer(lines)
	local input = vim.list_extend(vim.deepcopy(lines), { "/confirm" })
	api.nvim_buf_set_lines(0, 0, -1, false, input)
	api.nvim_win_set_cursor(0, { #input, 0 })
	local buf = api.nvim_get_current_buf()

	assert(vim.fn.maparg("<CR>", "i", false, true).callback() == "")
	assert(vim.wait(100, function()
		return not api.nvim_buf_is_valid(buf)
	end))
end

snippets.expand("{{session}}: {{topic}} / {{ topic }} / {{focus}}", context, function(text)
	result = text
end)

assert(api.nvim_win_get_config(0).title[1][1]:find("topic", 1, true))

completion.setup = original_setup
local input_buf = api.nvim_get_current_buf()

for _, text in ipairs({ "/", "/con", "  /conf" }) do
	api.nvim_buf_set_lines(input_buf, 0, -1, false, { text .. " " })
	api.nvim_win_set_cursor(0, { 1, #text })
	local start, suggestions = variable_candidates()

	assert(start == (text:find("/", 1, true)))
	assert(#suggestions == 1 and suggestions[1].word == "/confirm")

	require("aero.acp.path_menu").show(input_buf, start, suggestions)

	assert(vim.fn.maparg("<CR>", "i", false, true).callback() == "")
	assert(vim.wait(100, function()
		return api.nvim_buf_get_lines(input_buf, 0, 1, false)[1] == text:match("^%s*") .. "/confirm "
	end))
	assert(result == nil and api.nvim_buf_is_valid(input_buf))
end

for _, text in ipairs({ "/other", "Text /", "/confirm extra" }) do
	api.nvim_buf_set_lines(input_buf, 0, -1, false, { text .. " " })
	api.nvim_win_set_cursor(0, { 1, #text })

	assert(variable_candidates() == nil)
end

api.nvim_buf_set_lines(0, 0, -1, false, { "Text with /confirm inside it" })

assert(vim.fn.maparg("<CR>", "i", false, true).callback() == "<CR>")
assert(result == nil)

local lines = { "First sentence. Second sentence.", "", string.rep("100% {{date}} ", 1000), "Last line.", "" }
local value = table.concat(lines, "\n")
answer(lines)

assert(result == nil and api.nvim_win_get_config(0).title[1][1]:find("focus", 1, true))

answer({ "" })

assert(result == "test: " .. value .. " / " .. value .. " / ")

local cancellations = 0
snippets.expand("{{topic}}", context, function(text)
	assert(text == nil)

	cancellations = cancellations + 1
end)
api.nvim_win_close(0, true)
vim.wait(100, function()
	return cancellations == 1
end)

assert(cancellations == 1)

-- Exercise interactive insertion through the picker and preserve drafts on cancellation.
write(dir .. "/global.json", { { name = "Runtime", prompt = "{{session}}: {{topic}}" } })
api.nvim_buf_set_lines(buf, 0, -1, false, { "/prompt" })
snippets.open(chat)
vim.fn.maparg("<CR>", "n", false, true).callback()
answer(lines)

assert(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n") == "test: " .. value)

api.nvim_buf_set_lines(buf, 0, -1, false, { "/prompt" })
snippets.open(chat)
vim.fn.maparg("<CR>", "n", false, true).callback()
vim.fn.maparg("q", "n", false, true).callback()

assert(api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "/prompt")

-- Source context is taken from the remembered code window, not the composer.
vim.cmd("vsplit")
local source_win = api.nvim_get_current_win()
local source_buf = api.nvim_create_buf(true, false)
api.nvim_win_set_buf(source_win, source_buf)
api.nvim_buf_set_name(source_buf, dir .. "/example.lua")
vim.bo[source_buf].filetype = "lua"
api.nvim_buf_set_lines(source_buf, 0, -1, false, { "local answer = 42", "return answer" })
api.nvim_buf_set_mark(source_buf, "<", 1, 6, {})
api.nvim_buf_set_mark(source_buf, ">", 1, 11, {})
local namespace = api.nvim_create_namespace("snippet-test")
vim.diagnostic.set(namespace, source_buf, {
	{ lnum = 1, col = 0, message = "Example warning", severity = vim.diagnostic.severity.WARN },
})
vim.t.aero_code_win = source_win
vim.cmd("wincmd p")
api.nvim_win_set_buf(0, buf)
context = snippets.context(chat, "{{file}}")

assert(context.file == api.nvim_buf_get_name(source_buf) and context.filetype == "lua")
assert(context.selection == "answer", vim.inspect(context.selection))
assert(context.diagnostics:find("example.lua:2:1: WARN: Example warning", 1, true))
assert(context.workspace_name == vim.fs.basename(dir) and context.worktree_name == vim.fs.basename(dir))

local function command(args)
	local result = vim.system(args, { text = true }):wait()

	assert(result.code == 0, result.stderr)
end

command({ "git", "init", "-b", "snippet-branch", dir })
vim.fn.writefile({ "before" }, dir .. "/tracked.txt")
command({ "git", "-C", dir, "add", "tracked.txt" })
command({
	"git",
	"-C",
	dir,
	"-c",
	"user.name=Test",
	"-c",
	"user.email=test@example.com",
	"-c",
	"commit.gpgsign=false",
	"commit",
	"-m",
	"fixture",
})
vim.fn.writefile({ "after" }, dir .. "/tracked.txt")
context = snippets.context(chat, "{{branch}} {{diff}}")

assert(context.branch == "snippet-branch")
assert(context.diff:find("-before", 1, true) and context.diff:find("+after", 1, true))

vim.diagnostic.reset(namespace)
vim.fn.delete(dir, "rf")
print("prompt snippets: ok")
