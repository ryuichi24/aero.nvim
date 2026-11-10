-- Scene migration, shared membership, scoped content, and context restoration.
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local project = vim.fn.getcwd()
local root = vim.env.AERO_SCENE_TEST_ROOT or vim.fn.tempname()

if vim.env.AERO_SCENE_TEST_ROOT then
	require("aero.config").setup({ state_file = root .. "/state.json" })

	assert(require("aero.store").load())

	local scenes = require("aero.scenes")

	assert(scenes.current() == vim.env.AERO_SCENE_TEST_ID)
	assert(scenes.find(scenes.current()).last.session == "Client chat")
	assert(#require("aero.general").list() == 1)
	assert(#assert(require("aero.knowledge").catalog()).collections == 1)
	assert(#scenes.workspaces() == 1)

	vim.cmd("qa!")
	return
end

vim.fn.mkdir(root, "p")
local repo = root .. "/project"
vim.fn.mkdir(repo, "p")

assert(vim.system({ "git", "init", repo }):wait().code == 0)

-- Start from a pre-scenes state file and knowledge catalog.
local original = {
	workspaces = { { root = repo, name = "Legacy project" } },
	sessions = { [root .. "/general"] = { { name = "Legacy chat", agent = "opencode-acp" } } },
	sidebar = { general_open = false },
}
vim.fn.writefile({ vim.json.encode(original) }, root .. "/state.json")
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	companion = { auto_start = false },
})
local scenes = require("aero.scenes")
local store = require("aero.store")
local session = require("aero.session")
local general = require("aero.general")
local knowledge = require("aero.knowledge")
local dashboard = require("aero.dashboard")
local legacy = general.list()[1]
local collection = assert(knowledge.create_collection("Legacy knowledge"))
local space = assert(knowledge.create_space(collection.id, "Legacy space"))

assert(scenes.current() == "default" and #scenes.list() == 1)
assert(#scenes.workspaces() == 1 and #general.list() == 1)
assert(#assert(knowledge.catalog()).spaces == 1)
assert(not scenes.create(" \n"))
assert(not scenes.create("Default"))

local work = assert(scenes.create("Work"))

assert(not scenes.rename(work.id, "Default"))
assert(scenes.rename(work.id, "Client work"))
assert(work.id == scenes.find("Client work").id)
assert(scenes.switch(work.id))
assert(scenes.current() == work.id)
assert(#scenes.workspaces() == 0 and #general.list() == 0)
assert(#assert(knowledge.catalog()).collections == 0)
assert(#require("aero.knowledge.store").read().spaces == 1, "scoping must not remove persisted knowledge")

assert(scenes.membership(repo, true))
assert(#scenes.workspaces() == 1)
assert(scenes.membership(repo, true))
assert(#store.find_workspace(repo).scene_ids == 2, "membership must be idempotent")

assert(store.set_expanded(repo, false))
assert(scenes.workspaces()[1].expanded == false)
assert(store.find_workspace(repo).expanded == true, "scene folds must not change Default's workspace folds")

assert(store.set_expanded(repo, true))

local chat = assert(session.create(general.directory(), "opencode-acp", "Client chat"))
local client_collection = assert(knowledge.create_collection("Client research"))
local client_space = assert(knowledge.create_space(client_collection.id, "Client evidence"))

assert(#general.list() == 1 and general.list()[1] == chat)
assert(store.find_session(chat.worktree, chat.name).scene_id == work.id)
assert(#assert(knowledge.catalog()).spaces == 1)
assert(scenes.contains(chat) and not scenes.contains(legacy))
assert(scenes.contains({ worktree = knowledge.directory() .. "/spaces/" .. client_space.id }))
assert(not scenes.contains({ worktree = knowledge.directory() .. "/spaces/" .. space.id }))

-- Restoring a stopped conversation must not start its agent.
chat.fresh = false
general.show(chat)

assert(chat.chat and not chat.chat:alive())

local saved_chat = chat.chat
require("aero.inbox").add(saved_chat, "completed", { text = "Client research finished" })
dashboard.open()
local folds = require("aero.dashboard.folds")
local state = {}
folds.restore(state)

assert(state.general_open == nil, "new scenes must have independent sidebar folds")

for row, line in ipairs(api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false)) do
	if line:find("General", 1, true) then
		api.nvim_win_set_cursor(0, { row, 0 })
		vim.fn.maparg("h", "n", false, true).callback()
		vim.fn.maparg("l", "n", false, true).callback()
		break
	end
end

assert(scenes.switch("default"))
assert(#general.list() == 1 and general.list()[1] == legacy)
assert(#assert(knowledge.catalog()).collections == 1)
assert(chat.chat == saved_chat and not chat.chat:alive(), "switching must preserve session identity")

local header = api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, 1, false)[1]

assert(header:find("1 elsewhere", 1, true), "background-scene attention must remain visible")

folds.restore(state)

assert(state.general_open == false, "Default must retain its migrated sidebar folds")
assert(scenes.switch(work.id))
assert(vim.fn.bufwinid(chat.buf) ~= -1, "scene must restore its last conversation")
assert(chat.chat == saved_chat and not chat.chat:alive())

folds.restore(state)

assert(state.general_open == true)
assert(store.load())
assert(scenes.current() == work.id and #scenes.list() == 2)
assert(scenes.find(work.id).last.session == chat.name)

local restarted = vim.system({
	vim.v.progpath,
	"--headless",
	"-u",
	"NONE",
	"-i",
	"NONE",
	"-l",
	"tests/scenes.lua",
}, { cwd = project, env = { AERO_SCENE_TEST_ROOT = root, AERO_SCENE_TEST_ID = work.id }, text = true }):wait()

assert(restarted.code == 0, restarted.stderr .. restarted.stdout)

-- Failed state writes must not commit membership or scene changes.
local rename = vim.uv.fs_rename
vim.uv.fs_rename = function()
	return nil, "injected scene write failure"
end
local result, err = scenes.membership(repo, false)
vim.uv.fs_rename = rename

assert(not result and err:find("injected scene write failure", 1, true))
assert(#scenes.workspaces() == 1)
assert(scenes.membership(repo, false))
assert(#scenes.workspaces() == 0 and #scenes.workspaces(true) == 1)

-- Deletion keeps all content available in Default without copying files.
local catalog_path = knowledge.directory() .. "/catalog.json"
vim.uv.fs_rename = function(from, to)
	if to == catalog_path then
		return nil, "injected reassignment failure"
	end

	return rename(from, to)
end
result, err = scenes.delete(work.id)
vim.uv.fs_rename = rename

assert(not result and err:find("injected reassignment failure", 1, true))
assert(scenes.find(work.id), "failed reassignment must retain the scene")
assert(require("aero.knowledge.store").read().collections[2].scene_id == work.id)

-- If the state write fails after catalog reassignment, deletion remains safe to retry.
vim.uv.fs_rename = function(from, to)
	if to == root .. "/state.json" then
		return nil, "injected scene deletion failure"
	end

	return rename(from, to)
end
result, err = scenes.delete(work.id)
vim.uv.fs_rename = rename

assert(not result and err:find("injected scene deletion failure", 1, true))
assert(scenes.find(work.id))
assert(require("aero.knowledge.store").read().collections[2].scene_id == "default")

assert(scenes.delete(work.id))
assert(scenes.current() == "default" and #scenes.list() == 1)
assert(#general.list() == 2)
assert(#assert(knowledge.catalog()).collections == 2)
assert(#assert(knowledge.catalog()).spaces == 2)
assert(require("aero.knowledge.store").read().collections[2].scene_id == "default")
assert(chat.chat == saved_chat)
assert(not scenes.delete("default"))

local lines = api.nvim_buf_get_lines(api.nvim_get_current_buf(), 0, -1, false)

assert(lines[1]:find("Scene: Default", 1, true))

-- A real terminal process and its buffer survive switching away and back.
require("aero.config").options.agents.fixture = { cmd = { "sh", "-c", "sleep 60" } }
local running = assert(session.create(repo, "fixture", "Running fixture"))
local win = dashboard.open_worktree(repo)

assert(session.start(running, win))

local job, terminal_buf = running.job, running.buf
local other = assert(scenes.create("Other"))

assert(scenes.switch(other.id))
assert(vim.fn.jobwait({ job }, 0)[1] == -1, "switching stopped the hidden agent")
assert(api.nvim_buf_is_valid(terminal_buf))
assert(scenes.switch("default"))
assert(running.buf == terminal_buf and running.job == job)
assert(vim.t.aero_worktree == repo or vim.t.aero_worktree == vim.uv.fs_realpath(repo))

session.stop(running)

-- Default pickers are scoped; all-scene navigation remains available.
assert(scenes.switch(other.id))

local open_picker = require("aero.picker").open
local options
require("aero.picker").open = function(value)
	options = value
end
require("aero.workspaces").open()

assert(#options.items() == 0)

require("aero.workspaces").open("all")

assert(#options.items() == 1)

require("aero.picker").open = open_picker

assert(scenes.activate(legacy))
assert(scenes.current() == "default", "cross-scene attention/navigation must follow the session")

print("scene tests passed")
vim.cmd("qa!")
