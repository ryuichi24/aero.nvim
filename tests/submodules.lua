-- Run: nvim --headless -u NONE -l tests/submodules.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local function git(path, ...)
	local result = vim.system({ "git", "-C", path, ... }, { text = true }):wait()

	assert(result.code == 0, result.stderr)

	return vim.trim(result.stdout)
end

local function repository(name)
	local path = dir .. "/" .. name
	vim.fn.mkdir(path, "p")
	git(path, "init", "-b", "main")
	git(path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial")
	return path
end

local parent = repository("parent")
local source = repository("source")
git(parent, "-c", "protocol.file.allow=always", "submodule", "add", source, "libs/core")
local checkout = parent .. "/libs/core"
local external = dir .. "/core-fix"
git(checkout, "worktree", "add", "-b", "fix", external)
local leaf = repository("leaf")
git(checkout, "-c", "protocol.file.allow=always", "submodule", "add", leaf, "vendor/leaf")
vim.fn.writefile(
	{ '[submodule "missing"]', "\tpath = libs/missing", "\turl = ../missing" },
	parent .. "/.gitmodules",
	"a"
)
local modules = require("aero.submodules")
local changed = 0

local function update()
	changed = changed + 1
end

local entry = modules.entries(parent, update)

assert(entry.loading)
assert(modules.entries(parent, update) == entry)
assert(vim.wait(5000, function()
	return not entry.loading
end))
assert(#entry.list == 2 and entry.list[1].name == "libs/core")
assert(modules.initialized(checkout) and not modules.initialized(parent .. "/libs/missing"))

local function trees(path)
	local result

	assert(vim.wait(5000, function()
		result = modules.worktrees(path, update)
		return not result.loading
	end))
	assert(not result.err, result.err)

	return result
end

local listed = trees(checkout)

assert(#listed.list == 2)
assert(
	listed.list[1].path == vim.uv.fs_realpath(checkout),
	"absorbed submodule main checkout resolved to its Git directory"
)
assert(trees(external) == listed, "worktrees sharing Git storage must share discovery")
assert(trees(source) ~= listed, "independent repositories must not share worktree lists")
assert(#modules.entries(external, update).list == 0, "submodule entries leaked between worktrees")
assert(#modules.entries(source, update).list == 0)

local shared_git = require("aero.git")
shared_git.invalidate()
local synchronous = assert(shared_git.list(checkout))

assert(synchronous[1].path == vim.uv.fs_realpath(checkout), "shared Git listing exposed metadata as a checkout")
assert(shared_git.main_root(external) == vim.uv.fs_realpath(checkout), "shared root resolver missed the submodule")

local calls = 0
local system = vim.system
vim.system = function(...)
	calls = calls + 1
	return system(...)
end
trees(checkout)
modules.entries(parent, update)
shared_git.main_root(checkout)
shared_git.main_root(external)

assert(calls == 0, "cached discovery spawned Git")

modules.invalidate()
modules.entries(parent, update)
modules.invalidate()
local previous = changed
vim.wait(200, function()
	return false
end)

assert(changed == previous, "invalidated discovery published a stale callback")

vim.system = system
local aero = require("aero")
aero.setup({ state_file = dir .. "/state.json", animation = false })
require("aero.store").data.workspaces = { { root = parent, name = "Parent" } }
require("aero.git").remote_status = function(root)
	assert(root == parent, "nested discovery fetched a submodule remote")
end
aero.open()
local api = vim.api
local buf = api.nvim_get_current_buf()

local function find(text)
	for index, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find(text, 1, true) then
			return index
		end
	end
end

local function expand(text)
	api.nvim_win_set_cursor(0, { assert(find(text), text), 0 })

	for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
		if map.lhs == "l" then
			map.callback()
			return
		end
	end
end

expand("parent (main)")

assert(find("Submodules") and not find("libs/core"), "discovery must be lazy")

expand("Submodules")

assert(vim.wait(5000, function()
	return find("libs/core") ~= nil
end))
assert(find("libs/missing [not initialized]"))

expand("libs/core")

assert(vim.wait(5000, function()
	return find("core-fix (fix)") ~= nil
end))

expand("core-fix (fix)")

assert(find("no agents"), "nested worktrees must expose session controls")

for _ = 1, 2 do
	for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
		if map.lhs == "h" then
			map.callback()
		end
	end
end

assert(api.nvim_win_get_cursor(0)[1] == find("libs/core"), "nested worktree parent navigation failed")

expand("core (main)")
local core_line = assert(find("core (main)"))
api.nvim_win_set_cursor(0, { core_line + 1, 0 })

for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
	if map.lhs == "l" then
		map.callback()
	end
end

assert(
	vim.wait(5000, function()
		return find("vendor/leaf") ~= nil
	end),
	vim.inspect(api.nvim_buf_get_lines(buf, 0, -1, false))
)

require("aero.dashboard").refresh()

assert(
	vim.wait(5000, function()
		return find("vendor/leaf") ~= nil
	end),
	"refresh lost expanded descendants"
)

-- Report destinations include discovered submodule worktrees in both directions.
local reports = require("aero.reports")
local parent_ws = require("aero.store").data.workspaces[1]
local parent_path = vim.uv.fs_realpath(parent)
local external_path = vim.uv.fs_realpath(external)
local report = assert(reports.create_file(parent_path, parent_ws, "submodule-move", "findings"))
local picker = require("aero.picker")
local open_picker = picker.open

local function move_report(destination)
	local selected
	picker.open = function(opts)
		local paths = {}

		for _, choice in ipairs(opts.items()) do
			assert(not paths[choice.wt.path], "duplicate report destination")

			paths[choice.wt.path] = true

			if choice.wt.path == destination then
				selected = choice
			end
		end

		assert(selected, "report destination missing: " .. destination)

		opts.select(selected)
	end
	require("aero.dashboard").render()
	api.nvim_win_set_cursor(0, { assert(find("submodule-move.md")), 0 })

	for _, map in ipairs(api.nvim_buf_get_keymap(buf, "n")) do
		if map.lhs == "m" then
			map.callback()
		end
	end

	assert(selected, "report move action did not open the picker")

	return reports.directory(destination, selected.ws) .. "/submodule-move.md"
end

local moved = move_report(external_path)

assert(not vim.uv.fs_stat(report.path) and vim.uv.fs_stat(moved), "report was not moved into the submodule worktree")

local returned = move_report(parent_path)

assert(
	not vim.uv.fs_stat(moved) and vim.fn.readfile(returned)[1] == "findings",
	"report was not moved back to the parent"
)

picker.open = open_picker

-- Shared storage and enumeration agree with the sidebar's repository identity.
local child_root = vim.uv.fs_realpath(checkout)

assert(reports.directory(external_path, { root = child_root }) == reports.directory(external_path))
assert(
	require("aero.reference").directory(external_path, { root = child_root })
		== require("aero.reference").directory(external_path)
)

local dashboard = require("aero.dashboard")
local bridge = require("aero.companion")
local snapshot = bridge.dispatch("snapshot")
local remote_tree

for _, tree in ipairs(snapshot.worktrees) do
	if tree.path == external_path then
		remote_tree = tree
	end
end

assert(
	remote_tree and remote_tree.workspace == child_root and remote_tree.branch == "fix",
	"companion lost submodule metadata"
)
assert(vim.tbl_contains(
	vim.tbl_map(function(ws)
		return ws.root
	end, snapshot.workspaces),
	child_root
))

local sessions = require("aero.session")
require("aero.config").options.agents.fixture = { type = "acp", cmd = { "unused" } }
local start = sessions.start
sessions.start = function()
	return true
end
local created, create_err = bridge.dispatch("session_create", {
	operation_id = "submodule-create-0001",
	epoch = snapshot.epoch,
	workspace = child_root,
	worktree = external_path,
	agent = "fixture",
	name = "remote audit",
})
sessions.start = start

assert(created and created.status == "accepted", create_err)

local renamed, rename_err = bridge.dispatch("worktree_rename", {
	operation_id = "submodule-rename-0001",
	epoch = snapshot.epoch,
	workspace = child_root,
	worktree = external_path,
	target = remote_tree.target,
	name = "fix-audit",
})

assert(renamed and renamed.status == "accepted", rename_err)
assert(
	vim.wait(5000, function()
		for _, tree in ipairs(bridge.dispatch("snapshot").worktrees) do
			if tree.path == external_path and tree.branch == "fix-audit" then
				return true
			end
		end
	end),
	"companion branch rename did not refresh discovered worktrees"
)

local choices
local select = vim.ui.select
vim.ui.select = function(items)
	choices = items
end
dashboard.pick()
vim.ui.select = select

assert(
	choices and #choices == 1 and choices[1].session.key == created.session,
	"global picker omitted submodule session"
)

local auto = dir .. "/core-auto"
git(checkout, "worktree", "add", "-b", "auto", auto)
auto = vim.uv.fs_realpath(auto)
modules.invalidate(true)

assert(vim.wait(5000, function()
	local listing = modules.worktrees(checkout, update)
	return listing.list and #listing.list == 3
end))

local automatic = assert(sessions.create(auto, "opencode", "automatic audit"))
dashboard.render()

assert(
	vim.wait(5000, function()
		return find("automatic audit") ~= nil
	end),
	"fixture worktree did not expand automatically"
)

dashboard.collapse("worktrees")
expand("parent (main)")

assert(not find("automatic audit"), "collapse worktrees missed an automatically expanded descendant")

-- Reveal a nested checkout even when its entire ancestry was collapsed.
dashboard.collapse("all")
dashboard.close()
vim.t.aero_worktree = auto
local ancestry = modules.ancestry(auto)

assert(
	ancestry and ancestry.worktree == parent_path and ancestry.mount == child_root,
	"submodule ancestry retained path aliases"
)

dashboard.open(true)

assert(
	vim.wait(5000, function()
		local row = find("core-auto (auto)")
		return row and api.nvim_win_get_cursor(0)[1] == row
	end),
	"current submodule worktree was not revealed and selected"
)

vim.t.aero_worktree = nil
sessions.delete(automatic)

-- Warm rendering must not invoke synchronous Git identity resolution.
local listings = 0
vim.system = function(args, ...)
	if args[1] == "git" and args[4] == "worktree" and args[5] == "list" then
		listings = listings + 1
	end

	return system(args, ...)
end
dashboard.render()
vim.system = system

assert(listings == 0, "warm rendering launched Git worktree listing")

local old_head = trees(child_root).list[1].head
local pull = shared_git.pull
shared_git.pull = function(path, callback)
	git(
		path,
		"-c",
		"user.name=Test",
		"-c",
		"user.email=test@example.com",
		"commit",
		"--allow-empty",
		"-m",
		"updated checkout"
	)
	callback(true, "fixture fast-forward")
end
dashboard.pull(child_root)
shared_git.pull = pull

assert(
	vim.wait(5000, function()
		local listing = modules.worktrees(child_root, update)
		return listing.list and listing.list[1].head ~= old_head
	end),
	"pull did not refresh submodule HEAD"
)

-- An edited .gitmodules file is re-read without an explicit global refresh.
local before = modules.entries(parent_path, update)

assert(vim.wait(5000, function()
	return not before.loading
end))

vim.fn.writefile({ '[submodule "extra"]', "\tpath = libs/extra", "\turl = ../extra" }, parent .. "/.gitmodules", "a")
local edited = modules.entries(parent_path, update)

assert(vim.wait(5000, function()
	return not edited.loading
end))
assert(edited ~= before and #edited.list == #before.list + 1, "edited submodule entries remained stale")

modules.invalidate()
vim.wait(100, function()
	return false
end)
local pending = {}
vim.system = function(_, _, callback)
	table.insert(pending, callback)
	return {}
end

for index = 1, 6 do
	modules.worktrees("/fixture/" .. index, update)
end

assert(#pending == 2, "discovery exceeded its concurrency limit")

pending[1]({ code = 128, stderr = "fixture failure" })

assert(
	vim.wait(1000, function()
		return #pending == 3
	end),
	"queued discovery did not resume"
)

modules.invalidate()
pending[2]({ code = 128, stderr = "fixture failure" })
pending[3]({ code = 128, stderr = "fixture failure" })
vim.wait(100, function()
	return false
end)

assert(#pending == 3, "invalidated queued discovery was started")

vim.system = system

vim.cmd("qa!")
