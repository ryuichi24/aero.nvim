vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = require("aero.storage").canonical(vim.fn.tempname())
vim.fn.mkdir(root .. "/source/folder/nested", "p")
vim.fn.mkdir(root .. "/source/empty", "p")
vim.fn.mkdir(root .. "/worktree", "p")
vim.fn.writefile({ "# Evidence", "Copied interview" }, root .. "/source/folder/nested/note.md")
vim.fn.writefile({ "segment,value", "Enterprise,42" }, root .. "/source/cut.csv")
vim.fn.writefile({ "Keep until staged" }, root .. "/source/unsaved.md")
require("aero.config").setup({
	state_file = root .. "/state.json",
	reference_finder = { home = root .. "/source", directory = "references" },
})
local knowledge = require("aero.knowledge")
local store = require("aero.knowledge.store")
local importer = require("aero.knowledge.import")
local collection = assert(knowledge.create_collection("Work"))
local space = assert(knowledge.create_space(collection.id, "Research"))
local other = assert(knowledge.create_space(collection.id, "Other space"))
local f = knowledge.add_files(space.id)

local function select(name, key)
	for row, item in ipairs(f.entries) do
		if item.name == name then
			api.nvim_set_current_win(f.win)
			api.nvim_win_set_cursor(f.win, { row, 0 })
			vim.cmd("normal " .. key)
			return
		end
	end

	error("missing finder entry: " .. name)
end

local function sources(space_id)
	return store.find(store.read().spaces, space_id).sources
end

local function wait_for_ingestion()
	assert(vim.wait(15000, function()
		for _, job in ipairs(store.read().jobs) do
			if job.status == "processing" or job.status == "queued" then
				return false
			end
		end

		return true
	end, 20))
end

assert(vim.inspect(api.nvim_win_get_config(f.win).title):find("Source finder", 1, true))
assert(vim.inspect(api.nvim_win_get_config(f.stack_win).title):find("Work / Research", 1, true))

select("folder", "y")
select("cut.csv", "d")

assert(#f.staged == 0 and vim.bo[f.buf].modified)
assert(#sources(space.id) == 0)

vim.cmd.write()

assert(#f.staged == 2 and not vim.bo[f.buf].modified)
assert(#sources(space.id) == 0, "staging must not import before finishing")
assert(vim.fn.filereadable(root .. "/source/cut.csv") == 1)

select("folder", "l")
select("nested", "l")

assert(f.directory:match("/folder/nested$"))

vim.cmd("normal h")
vim.cmd("normal -")
select("unsaved.md", "y")
vim.cmd("normal q")

assert(not api.nvim_win_is_valid(f.stack_win))
assert(#sources(space.id) == 2 and #sources(other.id) == 0)
assert(vim.fn.filereadable(root .. "/source/cut.csv") == 0)
assert(vim.fn.filereadable(root .. "/source/folder/nested/note.md") == 1)
assert(vim.fn.filereadable(root .. "/source/unsaved.md") == 1)

local imported = {}

for _, source in ipairs(sources(space.id)) do
	imported[source.relative_path] = source
end

assert(imported["folder/nested/note.md"] and imported["cut.csv"])
assert(vim.fn.readfile(knowledge.directory() .. "/" .. imported["cut.csv"].path)[2] == "Enterprise,42")

wait_for_ingestion()

assert(sources(space.id)[1].status == "ready" and sources(space.id)[2].status == "ready")

-- An open finder retains its original target across both kinds of import.
f = require("aero.reference").open(root .. "/worktree")

assert(knowledge.add_files(other.id) == f)
assert(f.target_key == "reference:" .. root .. "/worktree")

select("unsaved.md", "y")
vim.cmd.write()
vim.cmd("normal q")

assert(vim.fn.filereadable(root .. "/worktree/references/unsaved.md") == 1)
assert(#sources(other.id) == 0)

f = knowledge.add_files(space.id)

assert(knowledge.add_files(other.id) == f)

select("unsaved.md", "y")
vim.cmd.write()
vim.cmd("normal q")

assert(#sources(space.id) == 3 and #sources(other.id) == 0)

local collision = { { path = root .. "/source/folder", action = "cut" } }
local ok, err = importer.transfer(space.id, collision)

assert(not ok and err:find("already exists", 1, true))
assert(vim.fn.filereadable(root .. "/source/folder/nested/note.md") == 1)
assert(not importer.transfer(other.id, { { path = root, action = "cut" } }))
assert(not importer.transfer(other.id, { { path = root .. "/source/empty", action = "cut" } }))
assert(vim.fn.isdirectory(root .. "/source/empty") == 1)
assert(not importer.transfer(other.id, {
	{ path = root .. "/source/folder", action = "cut" },
	{ path = root .. "/source/folder/nested/note.md", action = "copy" },
}))
assert(#sources(other.id) == 0)

vim.fn.mkdir(root .. "/duplicate", "p")
vim.fn.writefile({ "Different material" }, root .. "/duplicate/note.md")

assert(not importer.transfer(other.id, {
	{ path = root .. "/source/folder/nested/note.md", action = "cut" },
	{ path = root .. "/duplicate/note.md", action = "copy" },
}))
assert(vim.fn.filereadable(root .. "/source/folder/nested/note.md") == 1)
assert(#sources(other.id) == 0)

assert(vim.uv.fs_symlink(root .. "/source/folder/nested/note.md", root .. "/source/link.md"))
assert(not importer.transfer(other.id, { { path = root .. "/source/link.md", action = "cut" } }))
assert(vim.uv.fs_lstat(root .. "/source/link.md").type == "link")

-- A failed catalog write rolls back managed copies without removing originals.
local original_atomic = store.atomic
store.atomic = function(path, text)
	if path == knowledge.directory() .. "/catalog.json" then
		error("injected catalog failure")
	end

	return original_atomic(path, text)
end
ok, err = importer.transfer(other.id, { { path = root .. "/source/unsaved.md", action = "cut" } })
store.atomic = original_atomic

assert(not ok and err:find("injected catalog failure", 1, true))
assert(#sources(other.id) == 0 and vim.fn.filereadable(root .. "/source/unsaved.md") == 1)
assert(
	not vim.uv.fs_scandir_next(assert(vim.uv.fs_scandir(knowledge.directory() .. "/spaces/" .. other.id .. "/sources")))
)

-- A failed cut can be retried without duplicating the imported source.
local original_delete = vim.fn.delete
vim.fn.delete = function(path, flags)
	if path == root .. "/source/unsaved.md" then
		return -1
	end

	return original_delete(path, flags)
end
local cut = { { path = root .. "/source/unsaved.md", action = "cut" } }
ok, err = importer.transfer(other.id, cut)
vim.fn.delete = original_delete

assert(not ok and err:find("could not be removed", 1, true))
assert(#sources(other.id) == 1 and not cut[1].done)
assert(vim.fn.filereadable(root .. "/source/unsaved.md") == 1)
assert(importer.transfer(other.id, cut))
assert(#sources(other.id) == 1 and cut[1].done)
assert(vim.fn.filereadable(root .. "/source/unsaved.md") == 0)

-- Do not cut content changed after the committed copy was made.
vim.fn.writefile({ "Original content" }, root .. "/source/changed.md")
local changed = false
store.atomic = function(path, text)
	original_atomic(path, text)

	if path == knowledge.directory() .. "/catalog.json" and not changed then
		changed = true
		vim.fn.writefile({ "New content must be kept" }, root .. "/source/changed.md")
	end
end
local changing = { { path = root .. "/source/changed.md", action = "cut" } }
ok, err = importer.transfer(other.id, changing)
store.atomic = original_atomic

assert(not ok and err:find("source changed", 1, true))
assert(vim.fn.readfile(root .. "/source/changed.md")[1] == "New content must be kept")

changing[1].action = "copy"

assert(importer.transfer(other.id, changing))
assert(#sources(other.id) == 2)

-- A committed import must retain its raw file even if releasing the lock fails.
local release_space = assert(knowledge.create_space(collection.id, "Lock release"))
vim.fn.writefile({ "Retain committed material" }, root .. "/source/locked.md")
local original_rmdir = vim.uv.fs_rmdir
vim.uv.fs_rmdir = function(path)
	if path == knowledge.directory() .. "/catalog.json.lock" then
		return nil, "injected lock release failure"
	end

	return original_rmdir(path)
end
ok, err = importer.transfer(release_space.id, { { path = root .. "/source/locked.md", action = "cut" } })
vim.uv.fs_rmdir = original_rmdir

assert(not ok and err:find("lock release failure", 1, true))
assert(original_rmdir(knowledge.directory() .. "/catalog.json.lock"))
assert(#sources(release_space.id) == 1)
assert(vim.fn.filereadable(knowledge.directory() .. "/" .. sources(release_space.id)[1].path) == 1)
assert(vim.fn.filereadable(root .. "/source/locked.md") == 1)

-- Folder-targeted imports preserve their destination and reject sibling collisions.
local nested_space = assert(knowledge.create_space(collection.id, "Nested imports"))
local target = { directory = "folder/nested" }
vim.fn.writefile({ "Nested evidence" }, root .. "/source/nested.md")
f = knowledge.add_files(nested_space.id, target)

assert(vim.inspect(api.nvim_win_get_config(f.stack_win).title):find("folder/nested", 1, true))

select("nested.md", "y")
vim.cmd.write()
vim.cmd("normal q")

assert(sources(nested_space.id)[1].relative_path == "folder/nested/nested.md")

ok, err = importer.transfer(nested_space.id, { { path = root .. "/source/nested.md", action = "copy" } }, target)

assert(not ok and err:find("already exists", 1, true))
assert(importer.transfer(nested_space.id, { { path = root .. "/source/nested.md", action = "copy" } }))
assert(#sources(nested_space.id) == 2)

wait_for_ingestion()
vim.wait(10)
vim.fn.delete(root, "rf")
print("knowledge finder: navigation, staging, target isolation, copy/cut, rollback and retry passed")
vim.cmd.qa({ bang = true })
