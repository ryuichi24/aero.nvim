vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	default_agent = "fixture",
	agents = {
		fixture = { type = "acp", cmd = { "python3", vim.fn.getcwd() .. "/tests/fixtures/acp.py", "knowledge" } },
		terminal = { cmd = { "sh" } },
	},
})
local knowledge = require("aero.knowledge")
local agent = require("aero.knowledge.agent")
local sessions = require("aero.session")
local collection = assert(knowledge.create_collection("Work"))
local space = assert(knowledge.create_space(collection.id, "Research"))
local session_actions = require("aero.dashboard.session_actions")
local original_select, original_start = vim.ui.select, session_actions.start
local chosen_agent
session_actions.start = function(_, selected_agent)
	chosen_agent = selected_agent
end
vim.ui.select = function(items, opts, callback)
	assert(items[1] == "default")
	assert(vim.tbl_contains(items, "fixture"))
	assert(not vim.tbl_contains(items, "terminal"))
	assert(opts.format_item(items[1]) == "default (fixture)")

	callback("default", 1)
end
agent.new({ space_id = space.id })

assert(chosen_agent == "fixture")

vim.ui.select, session_actions.start = original_select, original_start
local directory = knowledge.directory() .. "/spaces/" .. space.id
local session = assert(sessions.create(directory, "fixture", "Evidence"))
local second = assert(sessions.create(directory, "fixture", "Separate question"))

assert(#agent.sessions({ space_id = space.id }) == 2)
assert(session.key ~= second.key)

local original_pick_sources = knowledge.pick_sources
local picked
knowledge.pick_sources = function(target, kind)
	assert(target == session)

	picked = kind
end
local local_commands = require("aero.acp.local_commands")

assert(local_commands.handle({ s = session }, "/source"))
assert(picked == "source")
assert(local_commands.handle({ s = session }, "/tag"))
assert(picked == "tag")
assert(not local_commands.handle({ s = { worktree = root .. "/project" } }, "/source"))
assert(not local_commands.handle({ s = { worktree = root .. "/project" } }, "/tag"))

local prompt_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(prompt_buf)
vim.api.nvim_buf_set_lines(prompt_buf, 0, -1, false, { "Question", "/source", "More detail" })
vim.api.nvim_win_set_cursor(0, { 2, 0 })

assert(require("aero.acp.prompt").command({ s = session, prompt_buf = prompt_buf }))
assert(picked == "source")
assert(vim.deep_equal(vim.api.nvim_buf_get_lines(prompt_buf, 0, -1, false), { "Question", "More detail" }))

knowledge.pick_sources = original_pick_sources

assert(sessions.start(session, nil, false))
assert(vim.wait(10000, function()
	return session.chat and session.chat.session_id and not session.chat.busy
end, 20))
assert(session.knowledge_transport)

local original_cwd = vim.fn.getcwd()
local knowledge_win = assert(agent.show(session))

assert(knowledge_win == require("aero.panel").win(), "knowledge session must open in the agent panel")
assert(vim.api.nvim_win_get_buf(knowledge_win) == session.buf)
assert(vim.wo[knowledge_win].winbar:find("Ask this space: Research", 1, true))
assert(vim.wo[knowledge_win].winbar:find("Tags: none", 1, true))

local info = require("aero.session_info")
info.toggle()
local info_win = assert(info.win())

assert(vim.api.nvim_get_current_win() == knowledge_win, "opening info must not steal focus")
assert(not vim.wo[knowledge_win].winbar:find("Ask this space", 1, true))
assert(
	table
		.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(info_win), 0, -1, false), "\n")
		:find("Ask this space: Research", 1, true)
)

vim.api.nvim_win_set_cursor(info_win, { 8, 0 })
info.update()
local mcp_lines = table.concat(require("aero.mcp_info").lines(session), "\n")

assert(mcp_lines:find("Scope: Ask this space: Research", 1, true))
assert(mcp_lines:find("Configured tools (1): aero_knowledge", 1, true))
assert(mcp_lines:find("Bridge protocol: 1", 1, true))
assert(mcp_lines:find("Knowledge protocol: 1", 1, true))
assert(not mcp_lines:find("Version: not reported", 1, true))
assert(vim.api.nvim_win_get_cursor(info_win)[1] == 8, "metadata refresh must preserve the info cursor")
assert(require("aero.panel").owns(info_win))

local info_height = vim.api.nvim_win_get_height(info_win)
vim.api.nvim_set_current_win(info_win)
local grow = vim.fn.maparg(require("aero.layout").keys(false).grow, "n", false, true)

assert(type(grow.callback) == "function", "info window must bind the configured resize controls")

grow.callback()

assert(vim.api.nvim_win_get_height(info_win) > info_height, "resize controls must grow the focused info window")
assert(vim.api.nvim_get_current_win() == info_win, "resizing info must preserve focus")

vim.api.nvim_set_current_win(knowledge_win)

-- Simulate a wider UI: the headless screen remains 80 columns.
local original_width = vim.api.nvim_win_get_width
vim.api.nvim_win_get_width = function(win)
	return win == knowledge_win and 110 or original_width(win)
end
require("aero.config").options.panel.info_auto_position = false
info.reflow()

assert(
	vim.api.nvim_win_get_position(info_win)[1] < vim.api.nvim_win_get_position(knowledge_win)[1],
	"disabled auto-position must keep info above the transcript"
)

require("aero.config").options.panel.info_auto_position = true
require("aero.config").options.panel.info_position_threshold_columns = 120
info.reflow()

assert(
	vim.api.nvim_win_get_position(info_win)[1] < vim.api.nvim_win_get_position(knowledge_win)[1],
	"custom threshold must keep info above a narrower panel"
)

require("aero.config").options.panel.info_position_threshold_columns = 100
info.reflow()
vim.api.nvim_win_get_width = original_width
local panel_position = vim.api.nvim_win_get_position(knowledge_win)
local info_position = vim.api.nvim_win_get_position(info_win)

assert(info_position[2] > panel_position[2], "wide info must move beside the transcript")
assert(vim.api.nvim_get_current_win() == knowledge_win, "reflow must preserve focus")
assert(vim.api.nvim_win_get_cursor(info_win)[1] == 8, "reflow must preserve the info cursor")

vim.api.nvim_win_set_width(knowledge_win, 40)
info.reflow()
panel_position = vim.api.nvim_win_get_position(knowledge_win)
info_position = vim.api.nvim_win_get_position(info_win)

assert(info_position[1] < panel_position[1], "narrow info must move above the transcript")

local normal = vim.tbl_extend("force", session, { worktree = root, name = "Normal session" })
local normal_lines = table.concat(info.lines(normal), "\n")

assert(normal_lines:find("Name: Normal session", 1, true))
assert(normal_lines:find("Agent: fixture", 1, true))
assert(normal_lines:find("Usage", 1, true))
assert(not normal_lines:find("── Knowledge ──", 1, true))

info.close()

assert(not info.win())
assert(vim.wo[knowledge_win].winbar:find("Ask this space: Research", 1, true))

local panel = require("aero.panel")
require("aero.config").options.panel.info_open_by_default = true
panel.close()

assert(panel.show(session))
assert(info.win(), "configured info window must open with the agent panel")

info.close()
panel.shown(session)

assert(not info.win(), "manually closed info must stay closed during session updates")

require("aero.config").options.panel.info_open_by_default = false

vim.cmd("tcd " .. vim.fn.fnameescape(original_cwd))

assert(agent.filter(session, {}))
assert(#agent.scope(session).source_ids == 0)
assert(agent.filter(session, nil))

local knowledge_store = require("aero.knowledge.store")

assert(knowledge_store.update(function(data)
	data.spaces[1].sources = {
		{
			id = "a",
			path = "spaces/" .. space.id .. "/sources/a",
			name = "pricing.md",
			tags = { "pricing", "important" },
		},
		{ id = "b", path = "spaces/" .. space.id .. "/sources/b", name = "notes.md", tags = { "other", "important" } },
	}
	return true
end))
assert(agent.label(session):find("Tags: important, other, pricing", 1, true))

info.toggle()
info_win = assert(info.win())
local scope_focus = vim.api.nvim_get_current_win()
local function info_text()
	return table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(info_win), 0, -1, false), "\n")
end

assert(info_text():find("Research / notes.md", 1, true))

vim.api.nvim_win_set_cursor(info_win, { 8, 0 })
vim.ui.select = function(items, _, callback)
	callback(items[#items])
end
knowledge.pick_sources(session, "source")

assert(info_text():find("1 selected sources", 1, true))
assert(info_text():find("1 selected sources\n    • Research / notes.md", 1, true))
assert(info_text():find("Research / notes.md", 1, true))
assert(not info_text():find("Research / pricing.md", 1, true))

vim.ui.select = function(items, _, callback)
	callback(items[2])
end
knowledge.pick_sources(session, "tag")
vim.ui.select = original_select

assert(info_text():find("2 selected sources", 1, true))
assert(info_text():find("Research / pricing.md", 1, true))
assert(info_text():find("Research / notes.md", 1, true))
assert(knowledge.tag_source(space.id, "a", { "updated" }))
assert(
	vim.wait(1000, function()
		return info_text():find("Tags: updated", 1, true) ~= nil
	end),
	"catalog tag changes must refresh the visible info panel"
)
assert(vim.api.nvim_get_current_win() == scope_focus, "scope refresh must preserve focus")
assert(vim.api.nvim_win_get_cursor(info_win)[1] == 8, "scope refresh must preserve the info cursor")
assert(knowledge.tag_source(space.id, "a", { "pricing", "important" }))
assert(agent.filter(session, nil))

info.close()

local tag_picker_steps = 0
vim.ui.select = function(items, opts, callback)
	tag_picker_steps = tag_picker_steps + 1

	if tag_picker_steps == 1 then
		assert(opts.prompt == "Tags · Research")
		assert(#items == 3)
		assert(items[1].name == "#important · 2 items")
		assert(items[2].name == "#other · 1 item")
		assert(items[3].name == "#pricing · 1 item")

		callback(items[3])
	else
		assert(opts.prompt == "Sources and notes tagged #pricing")
		assert(#items == 1 and items[1].id == "a")
		assert(items[1].name == "pricing.md")
	end
end
knowledge.browse_space(space, "Tags")
vim.ui.select = original_select

assert(tag_picker_steps == 2)
assert(agent.scope(session).source_ids == nil, "browsing tags must not change the session scope")

assert(agent.filter(session, { "a" }))
assert(agent.label(session):find("1 selected sources · Tags: important, pricing", 1, true))

local original_notify, scope_message = vim.notify
vim.notify = function(message)
	scope_message = message
end
agent.status(session)
vim.notify = original_notify

assert(scope_message:find("Research / pricing.md [important, pricing]", 1, true))
assert(not scope_message:find("notes.md", 1, true))
assert(agent.filter(session, {}))
assert(agent.label(session):find("0 selected sources · Tags: none", 1, true))
assert(agent.filter(session, nil))
assert(knowledge_store.update(function(data)
	data.spaces[1].sources = {}
	return true
end))

session.chat:prompt("Find evidence")

assert(vim.wait(10000, function()
	return not session.chat.busy
end, 20))
assert(session.chat.blocks[#session.chat.blocks].text == "new answer")
assert(session.chat.blocks[1].text == "Find evidence", "visible history should preserve the user's original prompt")

local dashboard = require("aero.dashboard")
local nested_snapshot = {
	icons = { expanded = "v", collapsed = ">" },
	workspaces = {},
	knowledge = {
		collections = { { id = "collection", name = "Collection" } },
		spaces = {
			{
				id = "space",
				collection_id = "collection",
				name = "Nested space",
				sources = {
					{ id = "source", name = "file.md", relative_path = "folder/nested/file.md", status = "ready" },
				},
			},
		},
	},
	knowledge_expanded = { ["knowledge-directory:space:/folder"] = false },
}
local collapsed_lines = require("aero.dashboard.model").build(nested_snapshot)

assert(table.concat(collapsed_lines, "\n"):find("> folder/", 1, true))
assert(not table.concat(collapsed_lines, "\n"):find("nested/", 1, true))
assert(not table.concat(collapsed_lines, "\n"):find("file.md", 1, true))

nested_snapshot.knowledge_expanded = {}
local expanded_lines = require("aero.dashboard.model").build(nested_snapshot)

assert(table.concat(expanded_lines, "\n"):find("nested/", 1, true))
assert(table.concat(expanded_lines, "\n"):find("file.md", 1, true))

nested_snapshot.knowledge.spaces[1].sources[1].tags = { "research", "important" }
local tag_lines, tag_items = require("aero.dashboard.model").build(nested_snapshot)
local tag_text = table.concat(tag_lines, "\n")

assert(tag_text:find("Tags", 1, true))
assert(tag_text:find("#important (1)", 1, true) < tag_text:find("#research (1)", 1, true))

local tagged_source

for _, item in pairs(tag_items) do
	if item.kind == "knowledge_source" and item.parent == "knowledge-tag:space:research" then
		tagged_source = item.source.id
	end
end

assert(tagged_source == "source")

nested_snapshot.knowledge_expanded["knowledge-tags:space"] = false
local hidden_tags = require("aero.dashboard.model").build(nested_snapshot)

assert(not table.concat(hidden_tags, "\n"):find("#research (1)", 1, true))

dashboard.open()
local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()

local function row(text)
	for index, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find(text, 1, true) then
			return index
		end
	end
end

assert(row("Knowledge base") and row("Research") and row("Evidence"))
assert(row("Sources") and row("Sessions") and row("Notes"))

local browse_space, new_session = knowledge.browse_space, agent.new
local selected_action, selected_scope
knowledge.browse_space = function(selected_space, action)
	assert(selected_space.id == space.id)

	selected_action = action
end
agent.new = function(scope)
	selected_scope = scope
end

for _, section in ipairs({
	{ "Sources", "Browse sources", "Add file" },
	{ "Notes", "Notes", "New note" },
}) do
	vim.api.nvim_win_set_cursor(win, { row(section[1]), 0 })
	vim.fn.maparg("a", "n", false, true).callback()

	assert(selected_action == section[3])
end

vim.api.nvim_win_set_cursor(win, { row("Sessions"), 0 })
vim.fn.maparg("a", "n", false, true).callback()

assert(selected_scope.space_id == space.id)

knowledge.browse_space, agent.new = browse_space, new_session

vim.api.nvim_win_set_cursor(win, { row("Sessions"), 0 })
vim.fn.maparg("<CR>", "n", false, true).callback()

assert(not row("Evidence"))
assert(row("Notes"))

vim.api.nvim_win_set_cursor(win, { row("Research"), 0 })
vim.fn.maparg("h", "n", false, true).callback()

assert(not row("Sessions"))

vim.fn.maparg("l", "n", false, true).callback()

assert(row("Sessions"))
assert(not row("Evidence"), "child collapse state should survive collapsing its space")

vim.api.nvim_win_set_cursor(win, { row("Sessions"), 0 })
vim.fn.maparg("l", "n", false, true).callback()

assert(row("Evidence"))

vim.fn.maparg("l", "n", false, true).callback()

assert(vim.api.nvim_win_get_cursor(win)[1] == row("Evidence"))

vim.fn.maparg("h", "n", false, true).callback()

assert(vim.api.nvim_win_get_cursor(win)[1] == row("Sessions"))

local notes = require("aero.knowledge.notes")
local draft = notes.edit(space.id, nil, "New research note")

assert(#knowledge.catalog().spaces[1].notes == 0)
assert(vim.bo[draft].filetype == "markdown")

vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "First draft" })
vim.api.nvim_buf_call(draft, function()
	vim.cmd.write()
end)
vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "Revised draft" })
vim.api.nvim_buf_call(draft, function()
	vim.cmd.write()
end)
local saved_notes = knowledge.catalog().spaces[1].notes

assert(#saved_notes == 1)
assert(saved_notes[1].name == "New research note")
assert(saved_notes[1].revision == 2)
assert(not vim.bo[draft].modified)

vim.api.nvim_set_current_win(win)
dashboard.render()

assert(row("New research note"))

local confirm = vim.fn.confirm
vim.fn.confirm = function()
	return 2
end
vim.api.nvim_win_set_cursor(win, { row("New research note"), 0 })
vim.fn.maparg("d", "n", false, true).callback()

assert(#knowledge.catalog().spaces[1].notes == 1)

vim.fn.confirm = function()
	return 1
end
vim.fn.maparg("d", "n", false, true).callback()
vim.fn.confirm = confirm

assert(#knowledge.catalog().spaces[1].notes == 0)
assert(not row("New research note"))

vim.api.nvim_win_set_cursor(win, { row("Knowledge base"), 0 })
vim.fn.maparg("h", "n", false, true).callback()

assert(not row("Research"))

vim.fn.maparg("l", "n", false, true).callback()

assert(row("Research"))

agent.show(session)

assert(dashboard.is_open())

sessions.stop(session)
sessions.delete(second)
require("aero.tasks.bridge").stop()
vim.fn.delete(root, "rf")
print("knowledge session tests passed")
vim.cmd.qa({ bang = true })
