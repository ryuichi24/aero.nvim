vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero.config").options.state_file = root .. "/state.json"
require("aero.config").options.knowledge.embedding_command = {
	"python3",
	"-c",
	[=[import json,sys; data=json.load(sys.stdin); print(json.dumps({"model":"fixture","vectors":[[1,0] if any(word in text.lower() for word in ["offline","disconnected"]) else [0,1] for text in data["texts"]]}))]=],
}
local knowledge = require("aero.knowledge")
local store = require("aero.knowledge.store")
local research = require("aero.knowledge.research")
local collection = assert(knowledge.create_collection("Work"))
local space = assert(knowledge.create_space(collection.id, "Customers"))
local other = assert(knowledge.create_space(collection.id, "Strategy"))
local markdown, csv = root .. "/interview.md", root .. "/survey.csv"
vim.fn.writefile({ "# Interview", "Customers need reliable offline access." }, markdown)
vim.fn.writefile({ "segment,revenue", '"Enterprise, large",100', "Small,25", "Small,75" }, csv)
local source = assert(knowledge.add_source(space.id, markdown))
local dataset = assert(knowledge.add_source(space.id, csv))
local queued_source = assert(knowledge.add_source(other.id, markdown))
local queued_job = store.read().jobs[3]

assert(queued_job.status == "queued" and queued_job.source_id == queued_source.id)
assert(require("aero.knowledge.ingest").cancel(queued_job.id))

assert(
	vim.wait(15000, function()
		local current = assert(knowledge.catalog())
		return current.spaces[1].sources[1].status == "ready" and current.spaces[1].sources[2].status == "ready"
	end, 20),
	vim.inspect(knowledge.catalog())
)

local hits = research.search({ space_id = space.id }, "offline")

assert(#hits.results == 1)
assert(hits.results[1].location.line == 1)
assert(hits.results[1].space == "Customers")

local parsed_citation = assert(research.parse_uri(hits.results[1].uri))

assert(parsed_citation.space_id == space.id and parsed_citation.source_id == source.id)
assert(parsed_citation.version == hits.results[1].version)
assert(not research.parse_uri("javascript:alert(1)"))

local old_buf = vim.api.nvim_get_current_buf()
local citation_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(citation_buf, 0, -1, false, { "[Interview evidence](" .. hits.results[1].uri .. ")" })
vim.api.nvim_set_current_buf(citation_buf)
vim.api.nvim_win_set_cursor(0, { 1, 2 })
local original_open, followed = research.open
research.open = function(citation)
	followed = citation
end

assert(research.follow_cursor())
assert(followed.source_id == source.id)

research.open = original_open
vim.api.nvim_set_current_buf(old_buf)
vim.api.nvim_buf_delete(citation_buf, { force = true })

assert(#research.search({ space_id = other.id }, "offline").results == 0)
assert(#research.search({ collection_id = collection.id }, "offline").results == 1)
assert(not pcall(research.read, { space_id = other.id }, source.id))
assert(knowledge.tag_source(space.id, source.id, { "customer", "offline", "customer" }))

local source_set = assert(knowledge.save_source_set(space.id, "Interviews", { source.id }))

assert(#store.read().spaces[1].sources[1].tags == 2)
assert(source_set.source_ids[1] == source.id)
assert(not knowledge.save_source_set(other.id, "Invalid", { source.id }))

local semantic
research.search_async({ space_id = space.id }, "disconnected", 10, function(result)
	semantic = result
end)

assert(vim.wait(10000, function()
	return semantic ~= nil
end, 20))
assert(#semantic.results == 1 and semantic.results[1].source_id == source.id)

local personal = assert(knowledge.create_collection("Personal"))
local personal_space = assert(knowledge.create_space(personal.id, "Personal research"))
local personal_source = assert(knowledge.add_source(personal_space.id, markdown))

assert(vim.wait(15000, function()
	return store.find(store.read().spaces, personal_space.id).sources[1].status == "ready"
end, 20))
assert(#research.search({ collection_id = collection.id }, "offline").results == 1)
assert(#research.search({ collection_ids = { collection.id, personal.id } }, "offline").results == 2)
assert(not pcall(research.read, { collection_ids = { collection.id } }, personal_source.id))

local binding = { knowledge_scope = { space_id = space.id }, session_key = "test-session" }
local tools = require("aero.knowledge.tools")
local aggregate =
	tools.call(binding, { action = "aggregate", source_id = dataset.id, table_name = "survey.csv", column = 2 })

assert(aggregate.sum == 200 and aggregate.mean == 200 / 3 and aggregate.count == 3)
assert(research.table({ space_id = space.id }, dataset.id, "survey.csv").rows[2][1] == "Enterprise, large")

local citation = hits.results[1]
local note = assert(
	tools.call(
		binding,
		{ action = "save_note", title = "Finding", body = "Offline access matters.", citations = { citation } }
	)
)
local revised_note = assert(
	require("aero.knowledge.notes").save(
		space.id,
		"Finding",
		"Offline access matters.\nKeep evidence links.",
		nil,
		note.id,
		"test-session",
		1
	)
)

assert(knowledge.tag_note(space.id, note.id, { "offline", "customer", "offline" }))

local tagged = tools.call(binding, { action = "list", tag = "offline" }).spaces[1]

assert(#tagged.sources == 1 and tagged.sources[1].id == source.id)
assert(#tagged.notes == 1 and tagged.notes[1].id == note.id)
assert(#tagged.notes[1].tags == 2)
assert(tools.call(binding, { action = "read_note", id = tagged.notes[1].id }).body:find("Keep evidence links", 1, true))
assert(#tools.call(binding, { action = "list", tag = "missing" }).spaces[1].notes == 0)

local narrowed = tools.call(binding, { action = "list", tag = "offline", source_ids = { dataset.id } }).spaces[1]

assert(#narrowed.sources == 0 and #narrowed.notes == 0)
assert(not knowledge.tag_note(other.id, note.id, { "offline" }))

assert(revised_note.revision == 2 and #revised_note.versions == 2)
assert(not require("aero.knowledge.notes").save(space.id, "Conflict", "Stale write", nil, note.id, "test-session", 1))

assert(not require("aero.knowledge.notes").stale(store.read(), note.citations))

vim.fn.writefile({ "# Interview", "Customers now prefer browser access." }, markdown)

assert(knowledge.refresh_source(space.id, source.id))

assert(vim.wait(15000, function()
	return store.read().spaces[1].sources[1].status == "ready"
end, 20))
assert(require("aero.knowledge.notes").stale(store.read(), note.citations))
assert(#research.search({ space_id = space.id, source_ids = { source.id } }, "offline").results == 0)
assert(research.search({ space_id = space.id }, "offline").results[1].kind == "note")
assert(research.search({ space_id = space.id }, "offline").results[1].stale)
assert(vim.fn.filereadable(store.directory() .. "/history/" .. source.id .. "/" .. citation.version) == 1)
assert(not require("aero.knowledge.notes").save(space.id, "Old citation", "Text", { citation }))

local agent = require("aero.knowledge.agent")
local scoped_session = { worktree = store.directory() .. "/spaces/" .. space.id }

assert(agent.scope(scoped_session).space_id == space.id)
assert(agent.context(scoped_session, "Question"):find("this space", 1, true))
assert(agent.context({ worktree = root }, "Question") == "Question")
assert(not pcall(tools.call, { knowledge_scope = { space_id = other.id } }, { action = "read", source_id = source.id }))
assert(
	not pcall(
		tools.call,
		{ knowledge_scope = { space_id = space.id, source_ids = {} } },
		{ action = "search", source_ids = { source.id }, query = "access" }
	)
)
assert(
	research.read({ space_id = space.id }, source.id, citation.chunk, citation.chunk, citation.version).version
		== citation.version
)

local linked = assert(knowledge.create_space(collection.id, "Linked folder"))
local inputs = root .. "/inputs"
vim.fn.mkdir(inputs, "p")
vim.fn.writefile({ "# Linked evidence", "Original content" }, inputs .. "/linked.md")
local folder = assert(knowledge.connect_folder(linked.id, inputs))

assert(vim.wait(15000, function()
	local current = store.find(store.read().spaces, linked.id)
	return #current.sources == 1 and current.sources[1].status == "ready"
end, 20))

local imported = store.find(store.read().spaces, linked.id).sources[1]

assert(imported.folder_id == folder.id and imported.relative_path == "linked.md")
assert(not knowledge.connect_folder(linked.id, root), "must not recursively ingest managed knowledge storage")

vim.fn.writefile({ "# Linked evidence", "Updated content with new findings" }, inputs .. "/linked.md")
require("aero.knowledge.sync").run()

assert(vim.wait(15000, function()
	local current = store.find(store.read().spaces, linked.id).sources[1]
	return current.status == "ready" and current.version ~= imported.version
end, 20))

-- Large evidence must be expandable without silently losing text or breaking UTF-8.
local current = store.read().spaces[1].sources[1]
local cache = store.directory() .. "/" .. current.extraction
local document = vim.json.decode(table.concat(vim.fn.readfile(cache), "\n"))
local large = string.rep("界", 13000) .. " unique-evidence " .. string.rep("tail ", 200)
document.chunks = {}

for index = 1, 25 do
	document.chunks[index] = { text = large, location = { page = index } }
end

store.atomic(cache, vim.json.encode(document))
store.update(function(data)
	local item = data.spaces[1].sources[1]
	item.status, item.issues = "ready_with_warnings", { "Text only" }
end)
local excerpts = tools.call(binding, { action = "search", query = "unique-evidence", source_ids = { source.id } })

assert(#excerpts.results == 5 and excerpts.total_results == 25)
assert(#excerpts.incomplete_sources == 0 and excerpts.warning_count == 1)
assert(excerpts.results[1].text:find("unique-evidence", 1, true))
assert(vim.fn.strchars(excerpts.results[1].text) <= 600 and excerpts.results[1].truncated)

local first_page = tools.call(binding, { action = "read", source_id = source.id })

assert(#first_page.chunks == 1 and first_page.next_chunk == 1 and first_page.next_offset == 12000)

local rest = tools.call(binding, {
	action = "read",
	source_id = source.id,
	first = first_page.next_chunk,
	offset = first_page.next_offset,
	version = first_page.version,
})

assert(first_page.chunks[1].text .. rest.chunks[1].text == large)
assert(rest.next_chunk == 2 and rest.next_offset == nil)

local catalog_page = tools.call(binding, { action = "list", limit = 1 })
local catalog_next = tools.call(binding, { action = "list", limit = 1, offset = catalog_page.next_offset })

assert(catalog_page.next_offset == 1 and catalog_page.total_items >= 2)
assert(catalog_page.spaces[1].sources[1].path == nil)
assert(catalog_next.spaces[1].sources[1].id ~= catalog_page.spaces[1].sources[1].id)

local table_source = store.read().spaces[1].sources[2]
local table_cache = store.directory() .. "/" .. table_source.extraction
local table_document = vim.json.decode(table.concat(vim.fn.readfile(table_cache), "\n"))
table_document.tables[1].rows = { { large }, { "next row" } }
store.atomic(table_cache, vim.json.encode(table_document))
local table_page = tools.call(binding, { action = "table", source_id = dataset.id, table_name = "survey.csv" })
local table_rest = tools.call(binding, {
	action = "table",
	source_id = dataset.id,
	table_name = "survey.csv",
	first = table_page.next_row,
	offset = table_page.next_offset,
})

assert(table_page.fragment_row == 1 and table_page.next_row == 1)
assert(vim.json.decode(table_page.row_fragment .. table_rest.row_fragment)[1] == large)
assert(table_rest.next_row == 2)

local long_note = assert(require("aero.knowledge.notes").save(space.id, "Long note", large, {}))
local note_page = tools.call(binding, { action = "read_note", id = long_note.id })
local note_rest = tools.call(binding, { action = "read_note", id = long_note.id, offset = note_page.next_offset })

assert(note_page.body .. note_rest.body == large)
assert(note_page.note.versions == nil and note_rest.next_offset == nil)
assert(not pcall(tools.call, binding, { action = "read_note", id = long_note.id, offset = 1000000 }))
assert(
	not pcall(tools.call, binding, { action = "table", source_id = dataset.id, table_name = "survey.csv", first = 99 })
)

vim.fn.delete(root, "rf")
print("knowledge research tests passed")
vim.cmd.qa({ bang = true })
