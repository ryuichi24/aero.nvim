-- Run: nvim --headless -u NONE -l tests/transcript_groups.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	acp = { max_tool_lines = 1, collapsed = { tools = true } },
	agents = { fixture = { type = "acp", cmd = { "false" } } },
})
local sessions = require("aero.session")
local s = sessions.create(vim.fn.getcwd(), "fixture")
assert(sessions.start(s, api.nvim_get_current_win(), true, nil, { history_only = true }))
local chat = s.chat
local setup = { kind = "info", text = "Old saved history without timestamps" }
local first = { kind = "user", text = "Inspect the source\nand explain the result" }
local message = { kind = "agent", text = "I will inspect the implementation." }
local thought = { kind = "thought", text = "Compare the source and tests.\nChoose a minimal fix." }
local read = {
	kind = "tool",
	id = "read",
	tool_kind = "read",
	status = "completed",
	title = "Read source.lua",
	rawInput = { path = "source.lua", preserved = "structured input" },
	rawOutput = "first output\nsecond output\nthird output",
}
local command = { kind = "tool", id = "test", tool_kind = "execute", status = "completed", title = "Run tests" }
local decision = { kind = "agent", text = "The implementation needs a fix." }
local edit = { kind = "tool", id = "edit", tool_kind = "edit", status = "completed", title = "Edit source.lua" }
local second = { kind = "user", text = "Now explain the fix" }
local reply = { kind = "agent", text = "Here is the explanation." }
chat.blocks = { setup, first, message, thought, read, command, decision, edit, second, reply }
local function render()
	chat:render()
	assert(
		vim.wait(2000, function()
			return not chat.render_pending
		end, 10),
		"render timed out"
	)
end
local function section(kind, block)
	for _, value in ipairs(chat.sections) do
		if value.kind == kind and value.key == block then
			return value
		end
	end
	error("missing " .. kind .. " section")
end
local function cursor(row)
	api.nvim_win_set_cursor(0, { row, 0 })
end
local function normal(keys)
	vim.cmd("normal! " .. keys)
end
render()
local lines = table.concat(chat.lines, "\n")
assert(lines:find("## Session setup", 1, true))
assert(lines:find("## Turn 1 — Inspect the source ⏎ and explain the result", 1, true))
assert(lines:find("## Turn 2 — Now explain the fix", 1, true))
assert(lines:find("### Message ·", 1, true), "untimestamped agent messages have no label")
assert(lines:find("### Tools · 2 calls · 1 Read, 1 Command", 1, true))
local turn1, turn2 = section("turn", first), section("turn", second)
local group = section("tools", read)
assert(turn1.last < turn2.first and section("tools", edit).first > chat.block_lines[decision])
assert(vim.fn.foldclosed(turn1.first) == -1, "prompt turn is collapsed by default")
assert(vim.fn.foldclosed(group.first) == group.first, "tool group is not collapsed by default")
assert(vim.fn.foldclosed(section("thought", thought).first) == section("thought", thought).first)
assert(vim.fn.foldtextresult(group.first):find("Tools · 2 calls", 1, true), "fold summary is not readable")
cursor(group.first)
normal("zo")
assert(vim.fn.foldclosed(group.first) == -1)
assert(vim.fn.foldclosed(section("tool", read).first) == section("tool", read).first)
cursor(section("tool", read).first)
normal("zo")
assert(vim.fn.foldclosed(section("tool", read).first) == -1)

-- A second view gets its own folds; changing it must not reset the first view.
local original_win = api.nvim_get_current_win()
vim.cmd("split")
local other_win = api.nvim_get_current_win()
render()
assert(vim.fn.foldclosed(section("tools", read).first) == section("tools", read).first)
normal("zR")
api.nvim_set_current_win(original_win)
assert(vim.fn.foldclosed(section("tool", read).first) == -1)
api.nvim_win_close(other_win, true)

-- Export from a stopped session includes all turns and untruncated data, independent of folds.
cursor(turn1.first)
normal("zc")
local exports = require("aero.exports")
local closed_export = exports.markdown(chat)
assert(closed_export:find("## Turn 2 — Now explain the fix", 1, true))
assert(closed_export:find("first output\nsecond output\nthird output", 1, true))
assert(closed_export:find('"preserved":"structured input"', 1, true))
assert(closed_export:find("<details>", 1, true) and closed_export:find("</details>", 1, true))
assert(not closed_export:find("more lines", 1, true))
local read_data = assert(closed_export:find("Tool protocol data · read", 1, true))
local next_message = assert(closed_export:find(decision.text, 1, true))
assert(read_data < next_message, "protocol data escaped its prompt/tool group")
normal("zR")
assert(
	exports.markdown(chat):gsub("%- Exported: [^\n]+", "") == closed_export:gsub("%- Exported: [^\n]+", ""),
	"display folds changed the exported content"
)

-- Preserve native fold choices and the reading position across streaming renders.
cursor(turn1.first)
normal("zc")
local row = api.nvim_win_get_cursor(0)[1]
reply.text = reply.text .. "\nMore streamed text."
render()
assert(vim.fn.foldclosed(section("turn", first).first) == section("turn", first).first)
assert(api.nvim_win_get_cursor(0)[1] == row, "streaming moved the reader to the tail")
cursor(section("turn", first).first)
normal("zo")
assert(vim.fn.foldclosed(section("tool", read).first) == -1, "closed parent lost its opened child state")
normal("zc")
vim.fn.maparg("]]", "n", false, true).callback()
assert(api.nvim_win_get_cursor(0)[1] == section("turn", second).first)
vim.fn.maparg("[[", "n", false, true).callback()
assert(api.nvim_win_get_cursor(0)[1] == section("turn", first).first)

-- Prompt-picker/inbox jumps open enclosing folds to reveal their target.
chat:goto_block(decision)
assert(vim.wait(2000, function()
	return api.nvim_win_get_cursor(0)[1] == chat.block_lines[decision]
end, 10))
assert(vim.fn.foldclosed(chat.block_lines[decision]) == -1)

-- A failed call exposes its group and turn, even after the user closed them.
cursor(section("tools", read).first)
normal("zc")
cursor(section("turn", first).first)
normal("zc")
command.status = "failed"
render()
assert(vim.fn.foldclosed(section("turn", first).first) == -1)
assert(vim.fn.foldclosed(section("tools", read).first) == -1)
assert(vim.fn.foldclosed(section("tool", command).first) == -1)
cursor(section("tools", read).first)
normal("zc")
cursor(section("turn", first).first)
normal("zc")
read.status = "failed"
render()
assert(vim.fn.foldclosed(section("tools", read).first) == -1, "a second failure stayed hidden")
assert(vim.fn.foldclosed(section("tool", read).first) == -1)

-- A new permission in an already failed/collapsed turn must still be exposed.
cursor(section("turn", first).first)
normal("zc")
local permission = {
	kind = "permission",
	title = "Approve command",
	options = { { optionId = "yes", name = "Allow", kind = "allow_once" } },
}
table.insert(chat.blocks, 8, permission)
render()
local permission_row = chat:option_range(permission)
assert(permission_row and vim.fn.foldclosed(permission_row) == -1)
assert(chat:goto_permission(false, permission))
assert(api.nvim_win_get_cursor(0)[1] == permission_row)

chat:save_history()
require("aero.history").flush(s)
local saved = require("aero.history").load(s)
assert(#saved.blocks == #chat.blocks and saved.sections == nil and saved.fold_views == nil)
local restored = setmetatable({ blocks = saved.blocks }, { __index = chat })
local restored_lines = require("aero.acp.render").build(restored)
assert(table.concat(restored_lines, "\n"):find("## Turn 2 — Now explain the fix", 1, true))

-- Override each initial fold default in a new turn; partial setup retained the
-- defaults checked above. Later renders must respect the reader's manual choices.
require("aero.config").options.acp.collapsed = {
	turns = true,
	thinking = false,
	tool_groups = false,
	tools = false,
}
local prompt = { kind = "user", text = "Configured fold defaults" }
local thinking = { kind = "thought", text = "Visible reasoning\nMore reasoning" }
local call = { kind = "tool", id = "configured", title = "Inspect source", status = "completed" }
local result = { kind = "agent", text = "Visible message" }
chat.blocks = { prompt, thinking, call, result }
render()
assert(vim.fn.foldclosed(section("turn", prompt).first) == section("turn", prompt).first)
cursor(section("turn", prompt).first)
normal("zo")
for _, item in ipairs({ { "thought", thinking }, { "tools", call }, { "tool", call } }) do
	assert(vim.fn.foldclosed(section(item[1], item[2]).first) == -1, "configured section stayed collapsed")
end
cursor(section("thought", thinking).first)
normal("zc")
thinking.text = thinking.text .. "\nStreamed reasoning"
render()
assert(vim.fn.foldclosed(section("thought", thinking).first) == section("thought", thinking).first)
assert(vim.fn.foldclosed(section("turn", prompt).first) == -1, "configured default reset a manual choice")
assert(exports.markdown(chat):find("Streamed reasoning", 1, true), "fold defaults hid exported reasoning")
sessions.delete(s)
vim.fn.delete(dir, "rf")
print("transcript groups: prompt turns, nested folds, streaming, navigation, alerts, history and export passed")
vim.cmd("qa!")
