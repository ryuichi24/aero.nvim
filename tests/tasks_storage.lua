-- Run: nvim --headless -u NONE -l tests/tasks_storage.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local storage = require("aero.tasks.storage")
local tasks = require("aero.tasks")
local config = require("aero.config")
local shared = require("aero.storage")
if vim.env.AERO_TASK_REOPEN_CHILD then
	config.setup({ tasks = { directory = "worktree" } })
	local boards = tasks.list({ root = vim.env.AERO_TASK_REOPEN_CHILD })
	assert(#boards == 2 and boards[1].count == 1 and #boards[1].orphans == 1)
	return
end
if vim.env.AERO_TASK_LOCK_CHILD then
	config.setup({ tasks = { directory = "worktree" } })
	local ok, err = storage.with_lock({ root = vim.env.AERO_TASK_LOCK_CHILD }, function()
		return true
	end)
	assert(not ok and err:find("lock is held", 1, true), "competing process stole workspace lock")
	return
end
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/one/repo", "p")
vim.fn.mkdir(dir .. "/two/repo", "p")
dir = shared.canonical(dir)
local ws, other = { root = dir .. "/one/repo" }, { root = dir .. "/two/repo" }
config.setup({ state_file = dir .. "/state.json", tasks = { directory = "data" } })
assert(storage.directory(ws) ~= storage.directory(other))
config.options.tasks.directory = dir .. "/custom root"
assert(storage.directory(ws) ~= storage.directory(other))
config.options.tasks.directory = "notes/tasks"
assert(storage.directory(ws) == ws.root .. "/notes/tasks")
assert(#tasks.list(ws) == 0 and not vim.uv.fs_stat(storage.directory(ws)), "listing created storage")
config.options.tasks.directory = function(root)
	assert(root == ws.root)
	return "exact tasks"
end
assert(storage.directory(ws) == ws.root .. "/exact tasks")
config.options.tasks.directory = function()
	return false
end
assert(not storage.directory(ws))
config.options.tasks.directory = "worktree"
assert(storage.directory(ws) == ws.root .. "/.aero/tasks")
local board = assert(tasks.create_board(ws, "A"))
local second = assert(tasks.create_board(ws, "B"))
local ticket = assert(tasks.create_ticket(ws, board.path, "todo", "One"))
local path, err = storage.ticket_path(
	second.path,
	"../" .. vim.fs.basename(vim.fs.dirname(board.path)) .. "/tickets/" .. vim.fs.basename(ticket.path)
)
assert(not path and err)
local alias = vim.fs.dirname(second.path) .. "/tickets/alias.md"
assert(vim.uv.fs_symlink(ticket.path, alias))
assert(not storage.ticket_path(second.path, "tickets/alias.md"), "symlink ticket alias accepted")
assert(vim.uv.fs_symlink(vim.fs.dirname(board.path), storage.directory(ws) .. "/alias"))
assert(#tasks.list(ws) == 2, "symlink board discovered")
assert(not tasks.read_board(ws, storage.directory(ws) .. "/alias/board.md"))
local original = assert(storage.read(board.path))
assert(not storage.create(board.path, "overwrite"), "exclusive creation overwrote board")
assert(not storage.write(board.path, "stale version", "overwrite"), "stale write succeeded")
assert(storage.read(board.path) == original)
local rename = vim.uv.fs_rename
vim.uv.fs_rename = function()
	return nil, "simulated rename failure"
end
assert(not tasks.rename_board(ws, board.path, "Failure"))
vim.uv.fs_rename = rename
assert(storage.read(board.path) == original, "failed write damaged source")
local ok, lock_err = storage.with_lock(ws, function()
	local process = vim.system(
		{ vim.v.progpath, "--headless", "-u", "NONE", "-l", "tests/tasks_storage.lua" },
		{ env = { AERO_TASK_LOCK_CHILD = ws.root }, text = true }
	):wait(15000)
	assert(process.code == 0, process.stderr)
	return true
end)
assert(ok, lock_err)
local lock = storage.directory(ws) .. "/.aero-tasks.lock"
assert(storage.create(lock, vim.json.encode({ pid = 99999999, host = vim.uv.os_gethostname() })))
assert(
	storage.with_lock(ws, function()
		return true
	end),
	"dead lock not recovered"
)
assert(not vim.uv.fs_stat(lock))
-- A board reference write can fail after ticket creation; the ticket stays recoverable.
local write = storage.write
storage.write = function()
	return nil, "simulated conflict"
end
local created, create_err = tasks.create_ticket(ws, board.path, "todo", "Orphan")
storage.write = write
assert(not created and create_err:find("recover the orphan", 1, true))
assert(#tasks.read_board(ws, board.path).orphans == 1)
local reopened = vim.system(
	{ vim.v.progpath, "--headless", "-u", "NONE", "-l", "tests/tasks_storage.lua" },
	{ env = { AERO_TASK_REOPEN_CHILD = ws.root }, text = true }
):wait(15000)
assert(reopened.code == 0, reopened.stderr)
-- Markdown discovery survives a fresh service module without JSON task data.
package.loaded["aero.tasks"] = nil
assert(#require("aero.tasks").list(ws) == 2)
vim.fn.delete(dir, "rf")
print(
	"Task storage tests passed (scoping, symlinks, exclusive writes, conflicts, process locks, stale recovery, orphans)."
)
