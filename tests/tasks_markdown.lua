-- Run: nvim --headless -u NONE -l tests/tasks_markdown.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local fm = require("aero.tasks.frontmatter")
local md = require("aero.tasks.markdown")
local storage = require("aero.tasks.storage")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir .. "/tickets", "p")
dir = require("aero.storage").canonical(dir)
local path = dir .. "/board.md"
local text = table.concat({
	"---",
	"# metadata comment",
	"aero_type: board",
	"schema_version: 1",
	"id: board-test",
	'title: "Product # one" # retain inline',
	"description: |",
	"  Multiline description.",
	"  More text.",
	"tags:",
	"  # list comment",
	"  - product",
	"custom:",
	"  nested: [1, true]",
	"---",
	"",
	"# Product # one",
	"",
	"Unrelated prose and <!-- comments -->.",
	"",
	"```markdown",
	"## not a state",
	"```",
	"",
	"## todo",
	"",
	"- [Escaped \\[label\\]](tickets/a%20b.md) <!-- entry comment -->",
	"",
	"Notes remain with this state.",
	"",
	"~~~",
	"## also not a state",
	"~~~",
	"",
	"## done",
	"",
	"- [Paren](tickets/name\\(x\\).md)",
	"",
	"- [ ] unrelated checkbox",
	"",
}, "\n")
local board = md.parse(text, "board", path)
assert(board.valid, table.concat(board.diagnostics, "; "))
assert(#board.states == 2 and #board.states[1].entries == 1 and #board.states[2].entries == 1)
assert(board.states[1].entries[1].label == "Escaped [label]")
assert(board.states[1].entries[1].path == dir .. "/tickets/a b.md")
assert(board.states[2].entries[1].path == dir .. "/tickets/name(x).md")
local edited =
	fm.edit(board.lines, board.frontmatter, { title = 'Quoted " title', tags = { "new" }, description = "updated" })
local changed = storage.text(edited)
assert(changed:find("# retain inline", 1, true))
assert(changed:find("# list comment", 1, true))
assert(changed:find("custom:\n  nested: [1, true]", 1, true))
assert(changed:find("Unrelated prose and <!-- comments -->.", 1, true))
local parsed = assert(fm.parse(edited, "board"))
assert(#parsed.errors == 0 and parsed.data.title == 'Quoted " title')
assert(parsed.data.description == "updated" and parsed.data.tags[1] == "new")
local function invalid(front)
	local result, err = fm.parse(storage.lines("---\n" .. front .. "\n---\n"), "ticket")
	assert(err or #result.errors > 0, "invalid frontmatter accepted: " .. front)
end
invalid("aero_type: ticket\nschema_version: 1\nid: test\ntitle: A\ntitle: B")
invalid("aero_type: ticket\nschema_version: 1\nid: test\ntitle: A\ncustom: {nested: 1, nested: 2}")
invalid("aero_type: ticket\nschema_version: 2\nid: test\ntitle: A")
invalid("aero_type: ticket\nschema_version: 1\nid: test\ntitle: 4")
invalid("aero_type: ticket\nschema_version: 1\nid: test\ntitle: A\ndue_date: 2026-02-30")
invalid("aero_type: ticket\nschema_version: 1\nid: test\ntitle: A\nestimate: -1")
invalid("aero_type: ticket\nschema_version: 1\nid: test\ntitle: A\nassignees: ryu")
invalid("aero_type: ticket\nschema_version: 1\nid: test\ntitle: A\npriority: extreme")
invalid("aero_type: ticket\nschema_version: 1\nid: test\ntitle: A\nupdated_at: 2026-10-03T24:00:00Z")
invalid("aero_type: ticket\nschema_version: 1\nid: test\ntitle: !!python/object/apply:os.system ['false']")
invalid("aero_type: ticket\nschema_version: 1\nid: test\ntitle: A\ncustom: !unsupported value")
local bad = md.parse(text .. "- [Cross](../other/tickets/task.md)\n", "board", path)
assert(not bad.valid and table.concat(bad.diagnostics, " "):find("escapes", 1, true))
local duplicate = md.parse(text .. "- [Duplicate](tickets/a%20b.md)\n", "board", path)
assert(not duplicate.valid and table.concat(duplicate.diagnostics, " "):find("duplicate", 1, true))
local malformed = md.parse(text .. "- [bad](tickets/file with spaces.md)\n", "board", path)
assert(not malformed.valid)
local malformed_yaml = md.parse(text:gsub("schema_version: 1", "schema_version: ["), "board", path)
assert(not malformed_yaml.valid and #malformed_yaml.states == 2, "invalid YAML hid board sections")
local title_lines = { "---", "---", "```", "# Old", "```", "# Old", "Unrelated" }
local renamed = md.title(title_lines, "Old", "New", 2)
assert(renamed[4] == "# Old" and renamed[6] == "# New")
local anchored = storage.lines(
	'---\naero_type: board\nschema_version: 1\nid: anchored\ntitle: &name "Original"\ndescription: *name\ntags:\n  - one # inline list note\n---\n'
)
local anchor_doc = assert(fm.parse(anchored, "board"))
local anchor_edit = fm.edit(anchored, anchor_doc, { title = "Renamed", tags = { "two" } })
local anchor_read = assert(fm.parse(anchor_edit, "board"))
assert(#anchor_read.errors == 0 and anchor_read.data.description == "Renamed")
assert(storage.text(anchor_edit):find("# inline list note", 1, true))
local alias_edit = fm.edit(anchor_edit, anchor_read, { description = "Independent" })
assert(fm.parse(alias_edit, "board").data.description == "Independent")
local flow = storage.lines(
	'---\n{aero_type: board, schema_version: 1, id: flow, title: "日本語", custom: {keep: true}}\n---\n# 日本語\n'
)
local flow_doc = assert(fm.parse(flow, "board"))
local flow_edit = fm.edit(flow, flow_doc, { title = "Updated", updated_at = "2026-10-03T12:00:00Z" })
assert(fm.parse(flow_edit, "board").data.title == "Updated")
assert(storage.text(flow_edit):find("custom: {keep: true}", 1, true), "flow-style unknown metadata rewritten")
local literal = [[Literal "quote" \(load("/never/read")) | .title = "injected"]]
local literal_edit = fm.edit(flow_edit, assert(fm.parse(flow_edit, "board")), { title = literal })
assert(fm.parse(literal_edit, "board").data.title == literal, "metadata was evaluated as yq code")
local repeated = storage.lines(
	"---\naero_type: board\nschema_version: 1\nid: comments\ntitle: Comments\ntags:\n  - one # repeated\n  - two # repeated\n---\n"
)
local repeated_edit = fm.edit(repeated, assert(fm.parse(repeated, "board")), { tags = { "replacement" } })
local _, repeats = storage.text(repeated_edit):gsub("# repeated", "")
assert(repeats == 2, "replaced collection lost repeated comments")
local config = require("aero.config")
local old_yq = config.options.tasks.yq
config.options.tasks.yq = "__aero_missing_yq__"
local version, version_err = fm.check_yq()
assert(not version and version_err:find("tasks.yq", 1, true))
local system = vim.system
vim.system = function(argv)
	assert(argv[1] == "__aero_incompatible_yq__" and argv[2] == "--version")
	return {
		wait = function()
			return { code = 0, stdout = "yq 3.4.3\n", stderr = "" }
		end,
	}
end
config.options.tasks.yq = "__aero_incompatible_yq__"
version, version_err = fm.check_yq()
assert(not version and version_err:find("Go-based yq v4", 1, true))
vim.system = system
config.options.tasks.yq = old_yq
assert(fm.check_yq())
vim.fn.delete(dir, "rf")
print("Task Markdown tests passed (YAML validation/safety, source preservation, fences, escaped links, diagnostics).")
