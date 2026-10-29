-- Only Neovim is required, including concurrent writer subprocesses.
vim.opt.rtp:prepend(vim.fn.getcwd())
local worker = vim.env.AERO_STATE_WORKER
local root = vim.env.AERO_STATE_ROOT or vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero.config").setup({ state_file = root .. "/state.json", companion = { auto_start = false } })
local store = require("aero.store")

if worker then
	store.load()
	vim.fn.writefile({}, root .. "/ready-" .. worker)

	while not vim.uv.fs_stat(root .. "/start") do
		vim.uv.sleep(5)
	end

	for index = 1, 8 do
		local name = worker .. "-" .. index

		assert(store.add_session(root, "fixture", function()
			vim.uv.sleep(10)
			return false
		end, name))
	end

	vim.cmd("qa!")
	return
end

local jobs = {}

for index = 1, 4 do
	table.insert(
		jobs,
		vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/state_transactions.lua" }, {
			env = { AERO_STATE_WORKER = tostring(index), AERO_STATE_ROOT = root },
			text = true,
		})
	)
end

assert(
	vim.wait(5000, function()
		for index = 1, 4 do
			if not vim.uv.fs_stat(root .. "/ready-" .. index) then
				return false
			end
		end

		return true
	end),
	"writers did not reach the shared stale-state barrier"
)

vim.fn.writefile({}, root .. "/start")

for _, job in ipairs(jobs) do
	local result = job:wait(15000)

	assert(result.code == 0, result.stderr .. result.stdout)
end

assert(store.load())
assert(#store.sessions(root) == 32, "concurrent writers lost updates")

local notifications = {}
vim.notify = function(message)
	table.insert(notifications, message)
end
local added = 0
require("aero.events").on("workspace_added", function()
	added = added + 1
end)
local rename = vim.uv.fs_rename
vim.uv.fs_rename = function()
	return nil, "injected write failure"
end
local ws, err = store.add_workspace(root)
vim.uv.fs_rename = rename

assert(ws == nil and err:find("injected write failure", 1, true))
assert(not store.find_workspace(root) and added == 0, "failed save committed memory or emitted success")
assert(not vim.uv.fs_stat(root .. "/state.json.lock"), "write failure retained lock")
assert(#notifications == 1)

local name, callback_err = store.add_session(root, "fixture", function()
	error("injected mutation failure")
end, "fails")

assert(name == nil and callback_err:find("injected mutation failure", 1, true))
assert(not store.find_session(root, "fails"))
assert(store.add_workspace(root), "failure prevented subsequent transactions")
assert(added == 1)

local lock = root .. "/state.json.lock"
vim.fn.mkdir(lock)
vim.fn.writefile({ "owner remains authoritative" }, lock .. "/owner.json")
local blocked, lock_err = store.set_expanded(root, false)

assert(blocked == nil and lock_err:find("state lock is held", 1, true))
assert(vim.fn.readfile(lock .. "/owner.json")[1] == "owner remains authoritative", "lock was stolen")
assert(store.find_workspace(root).expanded, "blocked transaction changed memory")

vim.fn.delete(lock, "rf")
vim.fn.writefile({ "invalid json" }, root .. "/state.json")
local changed, invalid_err = store.set_session_field(root, "1-1", "extra", true)

assert(changed == nil and invalid_err:find("invalid state JSON", 1, true))
assert(vim.fn.readfile(root .. "/state.json")[1] == "invalid json", "invalid state was overwritten")
assert(store.find_session(root, "1-1").extra == nil)

vim.fn.delete(root, "rf")
print("State transactions passed (concurrent writers, save/mutation failures, rollback, corrupt state).")
vim.cmd("qa!")
