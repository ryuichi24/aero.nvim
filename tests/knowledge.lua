vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero.config").options.state_file = root .. "/state.json"
local knowledge = require("aero.knowledge")
local collection = assert(knowledge.create_collection("Work"))
local space = assert(knowledge.create_space(collection.id, "Research"))
local original = root .. "/source.md"
vim.fn.writefile({ "# Evidence", "Verified finding" }, original)
local source = assert(knowledge.add_source(space.id, original))

assert(source.status == "not_indexed")
assert(vim.fn.readfile(knowledge.directory() .. "/" .. source.path)[2] == "Verified finding")
assert(vim.wait(15000, function()
	return knowledge.catalog().spaces[1].sources[1].status == "ready"
end, 20))

vim.fn.writefile({ "Changed original" }, original)

assert(knowledge.rename("spaces", space.id, "Renamed"))

package.loaded["aero.knowledge"] = nil
knowledge = require("aero.knowledge")
local data = assert(knowledge.catalog())

assert(data.spaces[1].id == space.id)
assert(data.spaces[1].name == "Renamed")
assert(data.spaces[1].collection_id == collection.id)
assert(vim.fn.readfile(knowledge.directory() .. "/" .. source.path)[2] == "Verified finding")
assert(not knowledge.create_space("missing", "Invalid"))
assert(not knowledge.create_collection("  "))
assert(not knowledge.add_source(space.id, root))
assert(#knowledge.catalog().spaces == 1)

local snapshot = {
	icons = { expanded = "v", collapsed = ">" },
	workspaces = {},
	knowledge = knowledge.catalog(),
}
local model = require("aero.dashboard.model")
local lines, items = model.build(snapshot)
local kinds = {}

for _, item in pairs(items) do
	kinds[item.kind] = item
end

assert(table.concat(lines, "\n"):find("Knowledge base", 1, true))
assert(kinds.knowledge_collection.collection.id == collection.id)
assert(kinds.knowledge_space.space.id == space.id)
assert(kinds.knowledge_space.parent == kinds.knowledge_collection.id)
assert(kinds.knowledge_manage.parent == "knowledge-group")

snapshot.knowledge_open = false
local _, collapsed = model.build(snapshot)

for _, item in pairs(collapsed) do
	assert(item.kind ~= "knowledge_space" and item.kind ~= "knowledge_collection")
end

assert(knowledge.tag_source(space.id, source.id, { "existing" }))

local metadata = require("aero.knowledge.metadata")
local buf = metadata.edit_tags(space.id, source.id)

assert(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1] == "existing")

local suggestion_note = assert(require("aero.knowledge.notes").save(space.id, "Tagged note", "Body", {}))

assert(knowledge.tag_note(space.id, suggestion_note.id, { "existing", "note-only" }))

local start, suggestions = metadata.tag_candidates(space.id, buf)

assert(start == 1 and #suggestions == 2)
assert(suggestions[1].word == "existing" and suggestions[2].word == "note-only")

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "existing", "NOTE" })
vim.api.nvim_win_set_cursor(0, { 2, 4 })
start, suggestions = metadata.tag_candidates(space.id, buf)

assert(start == 1 and #suggestions == 1 and suggestions[1].word == "note-only")

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "existing" })
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.bo[buf].modified = false

local function preview_lines()
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) ~= buf and vim.bo[vim.api.nvim_win_get_buf(win)].filetype == "text" then
			assert(vim.api.nvim_win_get_config(win).relative == "")

			return vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
		end
	end

	error("missing tag source preview")
end

assert(preview_lines()[1]:find("source.md", 1, true))

local tags_win = vim.api.nvim_get_current_win()
vim.cmd.wincmd("l")

assert(vim.api.nvim_get_current_buf() ~= buf)

local browse_space = knowledge.browse_space
local opened
knowledge.browse_space = function(_, _, id, action)
	opened = id

	assert(action == "Open")
end
vim.fn.maparg("<CR>", "n", false, true).callback()
knowledge.browse_space = browse_space

assert(opened == source.id)

vim.api.nvim_set_current_win(tags_win)

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " renamed ", "new, literal", "renamed", "" })

assert(metadata.edit_tags(space.id, source.id) == buf)
assert(knowledge.catalog().spaces[1].sources[1].tags[1] == "existing")

vim.cmd.write()

assert(vim.deep_equal(knowledge.catalog().spaces[1].sources[1].tags, { "new, literal", "renamed" }))
assert(not vim.bo[buf].modified)

vim.api.nvim_win_set_cursor(0, { 4, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })

assert(preview_lines()[1] == "Move to a tag to see matching items.")

vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })

assert(preview_lines()[1]:find("source.md", 1, true))

local select_ui = vim.ui.select
vim.ui.select = function()
	error("tag Enter must focus the source split without opening a picker")
end
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.fn.maparg("<CR>", "n", false, true).callback()
vim.ui.select = select_ui

assert(vim.api.nvim_get_current_buf() ~= buf)
assert(vim.api.nvim_get_current_line():find("source.md", 1, true))

vim.api.nvim_set_current_win(tags_win)

vim.api.nvim_buf_set_lines(buf, 0, -1, false, {})
vim.cmd.write()

assert(#knowledge.catalog().spaces[1].sources[1].tags == 0)

require("aero.config").options.knowledge.extractors = {
	{
		extensions = { ".custom" },
		command = {
			"sh",
			"-c",
			[[read -r request; printf '%s\n' '{"chunks":[{"text":"Custom evidence","location":{"section":"test"}}],"tables":[],"issues":["Custom warning"]}']],
		},
	},
}
local folder = root .. "/connected"
vim.fn.mkdir(folder, "p")
vim.fn.writefile({ "custom data" }, folder .. "/evidence.custom")

assert(knowledge.connect_folder(space.id, folder))
assert(knowledge.sync_folders(space.id))
assert(vim.wait(15000, function()
	local sources = knowledge.catalog().spaces[1].sources

	return #sources == 2 and sources[2].status == "ready_with_warnings"
end, 20))

local custom = knowledge.catalog().spaces[1].sources[2]
local document = vim.json.decode(table.concat(vim.fn.readfile(knowledge.directory() .. "/" .. custom.extraction), "\n"))

assert(document.chunks[1].text == "Custom evidence")
assert(document.chunks[1].location.section == "test")

vim.api.nvim_buf_delete(buf, { force = true })
vim.fn.writefile({ "broken JSON" }, knowledge.directory() .. "/catalog.json")

assert(not knowledge.create_collection("Must not overwrite"))
assert(vim.fn.readfile(knowledge.directory() .. "/catalog.json")[1] == "broken JSON")

vim.fn.delete(root, "rf")
print("knowledge tests passed")
vim.cmd.qa({ bang = true })
