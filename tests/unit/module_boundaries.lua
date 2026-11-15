-- Run from the repository root: python3 tests/run.py --unit module_boundaries
vim.opt.rtp:prepend(vim.fn.getcwd())
local knowledge = require("aero.knowledge")
local catalog = require("aero.knowledge.catalog")

assert(knowledge.catalog == catalog.catalog and type(knowledge.open) == "function")
assert(
	catalog.open == nil and package.loaded["aero.knowledge.ui"] == nil,
	"catalog operations loaded interactive browsing"
)

require("aero.tasks")

assert(package.loaded["aero.tasks.view"] == nil, "task service loaded board presentation")

local companion = require("aero.companion")

assert(companion == require("aero.companion.host"), "public lifecycle overrides must address the host owner")
assert(companion.dispatch == require("aero.companion.dispatch").dispatch)
assert(package.loaded["aero.companion_ui"] == nil, "loading companion capabilities opened presentation dependencies")

local store = require("aero.store")
store.data.sessions = { ["/project"] = { { name = "Agent", agent = "fixture" } } }
local worktrees = store.session_worktrees()
worktrees[1] = "/changed"

assert(store.session_worktrees()[1] == "/project", "enumeration exposed mutable store membership")
assert(store.active_scene() == "default")
assert(type(store.scenes()) == "table" and type(store.workspaces()) == "table" and type(store.sidebar()) == "table")

print("Feature module boundary tests passed.")
