-- nvim --headless -u NONE -l tests/companion_reference.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/main", "p")
vim.fn.mkdir(dir .. "/source/folder/nested", "p")
vim.fn.writefile({ "reference" }, dir .. "/source/folder/nested/note.md")
vim.fn.writefile({ "cut me" }, dir .. "/source/cut.txt")
dir = vim.fn.resolve(dir)
local main = dir .. "/main"
local git = require("aero.git")
git.list = function()
	return { { path = main, branch = "main" } }
end
local bridge

local function update(arguments)
	local result, err = bridge.dispatch("reference_update", vim.deepcopy(arguments))

	if result and result.status == "unknown" then
		assert(
			vim.wait(5000, function()
				result, err = bridge.dispatch("reference_update", vim.deepcopy(arguments))
				return not result or result.status ~= "unknown"
			end, 1),
			"reference transfer timed out in test"
		)
	end

	return result, err
end

git.main_root = function()
	return main
end
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	reference_finder = { home = dir .. "/source", directory = dir .. "/references" },
})
require("aero.store").add_workspace(main)
bridge = require("aero.companion")
local snapshot = bridge.dispatch("snapshot")
local tree = snapshot.worktrees[1]

assert(tree.reference_directory == dir .. "/references")

local serial = 0

local function params(extra)
	serial = serial + 1
	return vim.tbl_extend("force", {
		epoch = snapshot.epoch,
		target = tree.target,
		worktree = main,
		operation_id = ("reference-operation-%04d"):format(serial),
	}, extra or {})
end

local config = require("aero.config")

assert(vim.tbl_isempty(config.defaults.companion.reference_finder.roots), "remote sources are not denied by default")

local result, err = bridge.dispatch("reference_browse", params())

assert(not result and err:find("disabled"), "default finder exposed host directories")

result, err =
	update(params({ reference_action = "transfer", items = { { path = dir .. "/source/cut.txt", action = "cut" } } }))

assert(not result and err:find("disabled"), "default imports were not blocked")
assert(vim.fn.filereadable(dir .. "/source/cut.txt") == 1 and vim.fn.isdirectory(dir .. "/references") == 0)

config.options.companion.reference_finder.roots = false -- unrestricted access requires an explicit opt-in

local listing = assert(bridge.dispatch("reference_browse", params()))

assert(listing.path == dir .. "/source" and #listing.entries == 2)

result, err = bridge.dispatch("reference_browse", params({ target = "stale" }))

assert(not result and err:find("stale"))

result, err =
	bridge.dispatch("reference_update", params({ epoch = "stale", reference_action = "delete", path = "cut.txt" }))

assert(not result and err:find("stale"))

local transfer = params({
	reference_action = "transfer",
	items = {
		{ path = dir .. "/source/folder", action = "copy" },
		{ path = dir .. "/source/cut.txt", action = "cut" },
	},
})

assert(bridge.dispatch("reference_update", vim.deepcopy(transfer)).status == "unknown", "transfer blocked dispatch")

local editor_responsive = false
vim.schedule(function()
	editor_responsive = true
end)

assert(update(transfer).status == "accepted")
assert(editor_responsive, "transfer blocked the editor event loop")
assert(bridge.dispatch("reference_update", vim.deepcopy(transfer)).status == "accepted", "retry duplicated transfer")

for _, changed in ipairs({
	{ reference_action = "delete", path = "cut.txt" },
	{ items = { { path = dir .. "/source/folder", action = "cut" } } },
}) do
	local _, failure = bridge.dispatch("reference_update", vim.tbl_extend("force", vim.deepcopy(transfer), changed))

	assert(failure and failure:find("different arguments"), "receipt did not bind reference arguments")
end

assert(vim.fn.filereadable(dir .. "/source/cut.txt") == 0)
assert(vim.fn.filereadable(dir .. "/references/folder/nested/note.md") == 1)

config.options.companion.reference_finder.roots = {} -- existing reference management must work without source access

assert(
	bridge.dispatch(
		"reference_update",
		params({ reference_action = "rename", path = "folder/nested/note.md", name = "renamed.md" })
	).status == "accepted"
)
assert(vim.fn.filereadable(dir .. "/references/folder/nested/renamed.md") == 1)

result, err = bridge.dispatch("reference_update", params({ reference_action = "delete", path = "../source/cut.txt" }))

assert(not result and err:find("invalid reference path"))

vim.uv.fs_symlink(dir .. "/source", dir .. "/references/escape")
result, err = bridge.dispatch("reference_update", params({ reference_action = "delete", path = "escape/folder" }))

assert(not result and err:find("escapes storage"))

local session = assert(require("aero.session").create(main, "opencode-acp"))
local sent
session.chat = {
	state = "ready",
	client = {},
	blocks = {},
	queue = {},
	status = function()
		return "idle"
	end,
	activity = function() end,
	prompt = function(_, text)
		sent = text
	end,
}
snapshot = bridge.dispatch("snapshot")
local prompt = params({
	session = session.key,
	conversation = snapshot.sessions[1].conversation,
	text = "/reference select folder/nested/renamed.md\n\nInvestigate this.",
})

assert(bridge.dispatch("prompt", prompt).status == "accepted")
assert(sent:find(vim.json.encode(dir .. "/references/folder/nested/renamed.md"), 1, true))
assert(sent:find("Investigate this.", 1, true))
assert(bridge.dispatch(
	"prompt",
	params({
		session = session.key,
		conversation = snapshot.sessions[1].conversation,
		text = "/context select folder/nested/renamed.md\n\nLegacy draft.",
	})
).status == "accepted")
assert(sent:find("Read this reference file:", 1, true) and sent:find("Legacy draft.", 1, true))

local deletion = params({ reference_action = "delete", path = "folder" })

assert(bridge.dispatch("reference_update", deletion).status == "accepted")
assert(bridge.dispatch("reference_update", deletion).status == "accepted")
assert(vim.fn.isdirectory(dir .. "/references/folder") == 0)
assert(vim.fn.filereadable(dir .. "/source/folder/nested/note.md") == 1)

local security = require("aero.config").options.companion.reference_finder
security.roots = { dir .. "/source" }
result, err = bridge.dispatch("reference_browse", params({ path = dir }))

assert(not result and err:find("outside"), "finder escaped source policy")

listing = assert(bridge.dispatch("reference_browse", params()))

assert(listing.parent == listing.path, "finder offered parent outside allowed roots")

require("aero.config").options.reference_finder.home = dir
listing = assert(bridge.dispatch("reference_browse", params()))

assert(
	listing.path == dir .. "/source" and listing.roots[1] == dir .. "/source",
	"restricted finder did not fall back to an allowed source root"
)

require("aero.config").options.reference_finder.home = dir .. "/source"
result, err =
	update(params({ reference_action = "transfer", items = { { path = dir .. "/state.json", action = "copy" } } }))

assert(not result and err:find("outside"), "transfer escaped source policy")

security.allow_cut = false
result, err =
	update(params({ reference_action = "transfer", items = { { path = dir .. "/source/folder", action = "cut" } } }))

assert(not result and err:find("cutting is disabled"))
assert(vim.fn.isdirectory(dir .. "/source/folder") == 1)

security.allow_cut = true
vim.uv.fs_symlink(dir, dir .. "/source/folder/escape")
result, err =
	update(params({ reference_action = "transfer", items = { { path = dir .. "/source/folder", action = "copy" } } }))

assert(not result and err:find("outside"), "nested symlink escaped source policy")
assert(vim.fn.isdirectory(dir .. "/references/folder") == 0, "rejected import wrote reference data")

vim.uv.fs_unlink(dir .. "/source/folder/escape")
security.max_entries = 1
result, err =
	update(params({ reference_action = "transfer", items = { { path = dir .. "/source/folder", action = "copy" } } }))

assert(not result and err:find("max_entries"))

security.max_entries = 100000
security.max_bytes = 1
result, err = update(params({
	reference_action = "transfer",
	items = { { path = dir .. "/source/folder/nested/note.md", action = "copy" } },
}))

assert(not result and err:find("max_bytes"))

security.max_bytes = 1024 * 1024 * 1024
vim.fn.writefile({ "existing reference" }, dir .. "/references/note.md")
result, err = update(params({
	reference_action = "transfer",
	items = { { path = dir .. "/source/folder/nested/note.md", action = "copy" } },
}))

assert(
	not result and vim.fn.readfile(dir .. "/references/note.md")[1] == "existing reference",
	"collision cleanup deleted an existing file"
)

security.timeout_ms = 1
local old_lstat = vim.uv.fs_lstat
vim.uv.fs_lstat = function(path, callback)
	if not callback then
		return old_lstat(path)
	end

	vim.defer_fn(function()
		old_lstat(path, callback)
	end, 10)
end
result, err =
	update(params({ reference_action = "transfer", items = { { path = dir .. "/source/folder", action = "cut" } } }))
vim.uv.fs_lstat = old_lstat

assert(not result and err:find("timed out"))
assert(vim.fn.filereadable(dir .. "/source/folder/nested/note.md") == 1, "timed-out import removed source")

security.timeout_ms = 120000
vim.fn.mkdir(dir .. "/source/cancel-me", "p")

for i = 1, 20 do
	vim.fn.writefile({ "preserve me" }, dir .. "/source/cancel-me/" .. i .. ".txt")
end

local cancelled =
	params({ reference_action = "transfer", items = { { path = dir .. "/source/cancel-me", action = "cut" } } })

assert(bridge.dispatch("reference_update", vim.deepcopy(cancelled)).status == "unknown")

result, err = bridge.dispatch("reference_update", params({ reference_action = "delete", path = "note.md" }))

assert(not result and err:find("already running"), "mutation raced an active reference transfer")
assert(vim.wait(5000, function()
	return vim.fn.isdirectory(dir .. "/references/cancel-me") == 1
end, 1))

result, err = bridge.dispatch("reference_cancel", params({ transfer_id = cancelled.operation_id, target = "stale" }))

assert(not result and err:find("stale"))
assert(bridge.dispatch("reference_cancel", params({ transfer_id = cancelled.operation_id })).status == "accepted")

result, err = update(cancelled)

assert(not result and err:find("cancelled"))
assert(vim.fn.isdirectory(dir .. "/references/cancel-me") == 0, "cancelled import retained partial copy")

for i = 1, 20 do
	assert(vim.fn.filereadable(dir .. "/source/cancel-me/" .. i .. ".txt") == 1)
end

vim.fn.writefile({ "first source" }, dir .. "/source/first.txt")
result, err = update(params({
	reference_action = "transfer",
	items = {
		{ path = dir .. "/source/first.txt", action = "copy" },
		{ path = dir .. "/source/folder/nested/note.md", action = "copy" },
	},
}))

assert(not result and vim.fn.filereadable(dir .. "/references/first.txt") == 0, "failed batch left a partial copy")
assert(
	vim.fn.readfile(dir .. "/references/note.md")[1] == "existing reference",
	"batch cleanup removed colliding reference file"
)

vim.fn.mkdir(dir .. "/source/deep/one/two", "p")
security.max_depth = 1
result, err =
	update(params({ reference_action = "transfer", items = { { path = dir .. "/source/deep", action = "copy" } } }))

assert(not result and err:find("max_depth"))
assert(vim.fn.isdirectory(dir .. "/references/deep") == 0)

security.max_depth = 128
vim.fn.writefile({ "original data" }, dir .. "/source/changing.txt")
local old_read, changed = vim.uv.fs_read, false
vim.uv.fs_read = function(fd, size, offset, callback)
	if not callback then
		return old_read(fd, size, offset)
	end

	return old_read(fd, size, offset, function(read_err, data)
		vim.schedule(function()
			if not changed then
				changed = true
				vim.fn.writefile({ "new source data must survive" }, dir .. "/source/changing.txt")
			end

			callback(read_err, data)
		end)
	end)
end
result, err = update(
	params({ reference_action = "transfer", items = { { path = dir .. "/source/changing.txt", action = "cut" } } })
)
vim.uv.fs_read = old_read

assert(not result and err:find("source changed"), "changing source was not rejected")
assert(vim.fn.readfile(dir .. "/source/changing.txt")[1] == "new source data must survive")
assert(vim.fn.filereadable(dir .. "/references/changing.txt") == 0)

for _, key in ipairs({ "max_entries", "max_bytes", "max_depth", "timeout_ms" }) do
	security[key] = false
end

assert(
	update(
		params({ reference_action = "transfer", items = { { path = dir .. "/source/first.txt", action = "copy" } } })
	).status == "accepted"
)

security.max_listing_entries = 1
result, err = bridge.dispatch("reference_browse", params())

assert(not result and err:find("max_listing_entries"))

session.chat = nil
vim.fn.delete(dir, "rf")
print("companion reference: OK")
vim.cmd("qa!")
