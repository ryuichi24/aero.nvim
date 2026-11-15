-- Run from the repository root: python3 tests/run.py --unit session_registry
vim.opt.rtp:prepend(vim.fn.getcwd())
local store = require("aero.store")
local registry = require("aero.session.registry")
store.data.sessions = {
	["/first"] = { { name = "Agent", agent = "fixture" } },
	["/second"] = { { name = "Renamed", key = "/second::Original", agent = "fixture" } },
}

assert(#registry.loaded() == 0, "persisted definitions must not eagerly create runtime objects")
assert(registry.get("/first", "missing") == nil)
assert(
	registry.identity_taken("/second", "Original"),
	"a saved rename must reserve its original identity before lookup"
)
assert(not registry.identity_taken("/first", "Original"), "identity reservation leaked across worktrees")

local first = registry.get("/first", "Agent")
first.job, first.buf = 42, vim.api.nvim_create_buf(false, true)
vim.b[first.buf].aero_session = first.key

assert(first.key == "/first::Agent")
assert(registry.list("/first")[1] == first)
assert(registry.from_buf(first.buf) == first)

-- Replacing saved tables (as a locked reload does) must retain the live runtime object.
store.data.sessions["/first"] = { { name = "New name", key = first.key, agent = "fixture" } }
local renamed = registry.get("/first", "New name")

assert(renamed == first and renamed.name == "New name")
assert(renamed.job == 42 and registry.from_buf(first.buf) == first)
assert(registry.get("/first", "Agent") == nil)
assert(registry.identity_taken("/first", "Agent"), "renaming released an identity still used by history/runtime")

local second = registry.list("/second")[1]

assert(second.key == "/second::Original" and second ~= first)
assert(#registry.all() == 2 and #registry.loaded() == 2)

-- Polling must still see an instantiated runtime after another process removes its definition.
store.data.sessions["/first"] = nil

assert(#registry.all() == 1)
assert(#registry.loaded() == 2)
assert(registry.find(first.key) == first and registry.identity_taken("/first", "Agent"))

local snapshot = registry.loaded()
table.remove(snapshot)

assert(#registry.loaded() == 2, "mutating a membership snapshot changed the registry")

local prompt = vim.api.nvim_create_buf(false, true)
vim.b[prompt].aero_chat_key = second.key

assert(registry.find(vim.b[prompt].aero_chat_key) == second)
assert(registry.from_buf(prompt) == nil, "prompt lookup must not change transcript/terminal lookup semantics")

vim.api.nvim_set_current_buf(first.buf)

assert(registry.from_buf() == first)

registry.remove(first.key)

assert(registry.find(first.key) == nil and registry.from_buf(first.buf) == nil)
assert(not registry.identity_taken("/first", "Agent"))
assert(first.job == 42 and vim.api.nvim_buf_is_valid(first.buf), "membership removal performed backend cleanup")
assert(#registry.loaded() == 1 and #registry.all() == 1)

registry.remove(second.key)

assert(#registry.loaded() == 0)
assert(
	registry.identity_taken("/second", "Original"),
	"removing runtime membership changed saved identity reservations"
)

print("Session registry identity tests passed.")
