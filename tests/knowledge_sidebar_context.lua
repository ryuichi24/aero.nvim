vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero.config").setup({ state_file = root .. "/state.json", companion = { auto_start = false } })
local knowledge = require("aero.knowledge")
local store = require("aero.knowledge.store")
local collection = assert(knowledge.create_collection("Collection"))
local space = assert(knowledge.create_space(collection.id, "Space"))
local notes = require("aero.knowledge.notes")
local note = assert(notes.save(space.id, "Note", "Body", {}))

assert(knowledge.tag_note(space.id, note.id, { "important" }))

local middle = api.nvim_get_current_win()
local sidebar = api.nvim_create_buf(false, true)
local sidewin = api.nvim_open_win(sidebar, false, { split = "left", width = 35 })
vim.bo[sidebar].filetype = "Aero"
require("aero.navigation").set_dashboard({ state = { win = sidewin, target = middle } })
local model = require("aero.dashboard.model")
local view = require("aero.dashboard.view")
local ns = api.nvim_get_namespaces().AeroSidebarContext
local state = { buf = sidebar, target = middle, items = {} }

local function render(expanded)
	state.knowledge_catalog = assert(knowledge.catalog())
	local lines, items, marks = model.build({
		icons = require("aero.config").options.icons,
		workspaces = {},
		knowledge = state.knowledge_catalog,
		knowledge_expanded = expanded or {},
	})
	view.render(state, lines, items, marks)
end

local function marked(id)
	for _, mark in ipairs(api.nvim_buf_get_extmarks(sidebar, ns, 0, -1, { details = true })) do
		if state.items[mark[2] + 1].id == id then
			return true
		end
	end

	return false
end

notes.edit(space.id, note.id)
render()

assert(marked("knowledge-note:" .. note.id), "opened note lacks an indicator")
assert(marked("knowledge-notes:" .. space.id), "Notes section lacks an indicator")
assert(marked("knowledge-tag:" .. space.id .. ":important"), "tag alias lacks an indicator")
assert(marked("knowledge-space:" .. space.id))
assert(marked("knowledge-collection:" .. collection.id))
assert(marked("knowledge-group"))

render({ ["knowledge-notes:" .. space.id] = false, ["knowledge-tags:" .. space.id] = false })

assert(marked("knowledge-notes:" .. space.id), "collapsed Notes lost its indicator")

render({ ["knowledge-collection:" .. collection.id] = false })

assert(marked("knowledge-collection:" .. collection.id), "collapsed collection lost its note context")

require("aero.knowledge.metadata").edit_tags(space.id, note.id, "notes")
render()

assert(marked("knowledge-tags:" .. space.id), "tag editor lacks a Tags indicator")
assert(marked("knowledge-note:" .. note.id), "tag editor lost its note identity")

-- Replacing the reader buffer must clear document indicators, even in the same tab.
api.nvim_win_set_buf(middle, api.nvim_create_buf(false, true))
view.refresh_context(state)

assert(not marked("knowledge-group"), "closed document left stale knowledge context")

local source = {
	id = "abc123",
	name = "source.txt",
	path = "spaces/" .. space.id .. "/sources/abc123",
	relative_path = "nested/deeper/source.txt",
	status = "ready",
	version = string.rep("a", 64),
	extraction = "cache/abc123/" .. string.rep("a", 64) .. ".json",
	tags = { "evidence" },
}
store.atomic(store.directory() .. "/" .. source.path, "Source body\n")
store.atomic(
	store.directory() .. "/" .. source.extraction,
	vim.json.encode({
		version = source.version,
		chunks = { { text = "Source body", location = { line = 1 } }, { text = "Page body", location = { page = 2 } } },
		tables = {},
		issues = {},
	})
)

assert(store.update(function(data)
	table.insert(data.spaces[1].sources, source)
	return true
end))

knowledge.browse_space(space, "Browse sources", source.id, "Open")
render()

assert(marked("knowledge-source:" .. source.id), "original source lacks an indicator")
assert(marked("knowledge-sources:" .. space.id))
assert(marked("knowledge-directory:" .. space.id .. ":/nested"))

render({ ["knowledge-directory:" .. space.id .. ":/nested"] = false })

assert(marked("knowledge-directory:" .. space.id .. ":/nested"), "collapsed source directory lost context")

local metadata = require("aero.knowledge.metadata")
metadata.extraction_details(space.id, source.id)
render()

assert(marked("knowledge-source:" .. source.id), "extraction details lost source identity")

metadata.extracted_content(space.id, source.id)
render()

assert(marked("knowledge-source:" .. source.id), "extracted content lost source identity")

for chunk = 1, 2 do
	require("aero.knowledge.research").open({
		space_id = space.id,
		source_id = source.id,
		version = source.version,
		chunk = chunk,
	})
	render()

	assert(api.nvim_get_current_win() == middle, "citation replaced the sidebar")
	assert(marked("knowledge-source:" .. source.id), "citation lost source identity")
end

metadata.edit_tags(space.id, source.id)
render()

assert(marked("knowledge-tags:" .. space.id), "source tag editor lacks its section indicator")
assert(marked("knowledge-source:" .. source.id))

vim.fn.delete(root, "rf")
print("knowledge sidebar document context: ok")
vim.cmd("qa!")
