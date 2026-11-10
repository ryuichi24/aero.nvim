-- Metadata upgrades are durable, idempotent, locked, and independent of runtime persistence options.
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local path = root .. "/state.json"
local config = require("aero.config")
config.setup({ state_file = path, persist_sessions = false, persist_buffers = false })
local store = require("aero.store")
local catalog = require("aero.knowledge.store")

local function save(file, data)
	vim.fn.writefile({ vim.json.encode(data) }, file)
end

local function text(file)
	return table.concat(vim.fn.readfile(file), "\n")
end

local function read(file)
	return vim.json.decode(text(file))
end

local legacy = {
	workspaces = { { path = root .. "/repo" }, { root = root .. "/shared", scene_ids = { "custom" } } },
	sessions = {
		[root .. "/general"] = {
			{ name = "old", agent = "fixture", key = "stable-key", acp_session_id = "remote-id" },
			{ name = "owned", agent = "fixture", scene_id = "custom" },
		},
	},
	worktree_buffers = { [root .. "/repo"] = { path = root .. "/source.lua", cursor = { 12, 3 } } },
	scenes = { { id = "default", name = "Default" }, { id = "custom", name = "Custom" } },
	active_scene = "custom",
	extra = { preserved = true },
}
save(path, legacy)

assert(store.load())

local migrated = read(path)

assert(migrated.version == 1 and migrated.active_scene == "custom")
assert(migrated.workspaces[1].scene_ids[1] == "default")
assert(migrated.workspaces[2].scene_ids[1] == "custom")
assert(migrated.sessions[root .. "/general"][1].scene_id == "default")
assert(migrated.sessions[root .. "/general"][2].scene_id == "custom")
assert(migrated.sessions[root .. "/general"][1].key == "stable-key")
assert(migrated.sessions[root .. "/general"][1].acp_session_id == "remote-id")
assert(vim.deep_equal(migrated.worktree_buffers, legacy.worktree_buffers))
assert(migrated.extra.preserved)
assert(next(store.data.sessions) == nil and next(store.data.worktree_buffers) == nil)

local saved = text(path)
local atomic = require("aero.atomic_file")
local write = atomic.write
atomic.write = function()
	error("an already-migrated file must not be rewritten")
end

assert(store.load())
assert(text(path) == saved)

atomic.write = write

-- Migration failure retains both the original file and the last in-memory state.
save(path, legacy)
local original, memory = text(path), vim.deepcopy(store.data)
local rename = vim.uv.fs_rename
vim.uv.fs_rename = function()
	return nil, "injected migration failure"
end
local ok, err = store.load()
vim.uv.fs_rename = rename

assert(not ok and err:find("injected migration failure", 1, true))
assert(text(path) == original and vim.deep_equal(store.data, memory))
assert(not vim.uv.fs_stat(path .. ".lock"))
assert(store.load(), "migration must be retryable")

-- An edit between the initial read and lock acquisition must survive migration.
save(path, legacy)
local lock = require("aero.state_lock")
local with_lock = lock.with_lock
lock.with_lock = function(file, callback)
	local latest = read(file)
	latest.concurrent_edit = "keep me"
	save(file, latest)
	return with_lock(file, callback)
end

assert(store.load())
assert(read(path).concurrent_edit == "keep me")

lock.with_lock = with_lock

-- Reject future schemas without downgrading or changing memory.
save(path, { version = 999, workspaces = {} })
original, memory = text(path), vim.deepcopy(store.data)
ok, err = store.load()

assert(not ok and err:find("unsupported Aero state version", 1, true))
assert(text(path) == original and vim.deep_equal(store.data, memory))

-- Knowledge upgrades preserve source locations, citation metadata, and existing owners.
local directory = catalog.directory()
vim.fn.mkdir(directory .. "/spaces/b/sources", "p")
local source = directory .. "/spaces/b/sources/c"
vim.fn.writefile({ "stable evidence" }, source)
local catalog_path = directory .. "/catalog.json"
local old_catalog = {
	version = 1,
	collections = { { id = "a", name = "Legacy" }, { id = "d", name = "Owned", scene_id = "custom" } },
	spaces = {
		{
			id = "b",
			name = "Space",
			collection_id = "a",
			sources = {
				{
					id = "c",
					name = "Source",
					path = "spaces/b/sources/c",
					status = "ready",
					citations = { "citation" },
				},
			},
		},
	},
	jobs = { { id = "job", status = "queued", source_id = "c" } },
	research_scopes = { { id = "scope", scope = { collection_ids = { "a" } } } },
}
save(catalog_path, old_catalog)
original = text(catalog_path)
vim.uv.fs_rename = function()
	return nil, "injected catalog migration failure"
end
local data, failure = catalog.catalog()
vim.uv.fs_rename = rename

assert(not data and failure:find("injected catalog migration failure", 1, true))
assert(text(catalog_path) == original)
assert(not vim.uv.fs_stat(catalog_path .. ".lock"))

data = catalog.read()

assert(data.version == 2 and read(catalog_path).version == 2)
assert(data.collections[1].scene_id == "default" and data.collections[2].scene_id == "custom")
assert(vim.deep_equal(data.spaces[1].sources, old_catalog.spaces[1].sources))
assert(vim.deep_equal(data.jobs, old_catalog.jobs))
assert(vim.deep_equal(data.research_scopes, old_catalog.research_scopes))
assert(text(source) == "stable evidence")

saved = text(catalog_path)
atomic.write = function()
	error("an already-migrated catalog must not be rewritten")
end

assert(catalog.read().version == 2)
assert(text(catalog_path) == saved)

atomic.write = write
save(catalog_path, { version = 999, collections = {}, spaces = {} })
original = text(catalog_path)
data, failure = catalog.catalog()

assert(not data and failure:find("invalid knowledge catalog version", 1, true))
assert(text(catalog_path) == original)

-- Writers already holding their lock can migrate without acquiring it recursively.
save(path, legacy)
config.options.persist_sessions = true
config.options.persist_buffers = true

assert(store.add_session(root .. "/general", "fixture", nil, "new"))
assert(read(path).version == 1 and #read(path).sessions[root .. "/general"] == 3)

save(catalog_path, old_catalog)

assert(catalog.update(function(value)
	assert(value.version == 2 and value.collections[1].scene_id == "default")

	value.collections[1].name = "Updated"
	return true
end))
assert(read(catalog_path).collections[1].name == "Updated")

print("persistence migrations passed")
vim.cmd("qa!")
