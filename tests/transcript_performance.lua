-- Exercise the real streaming renderer against a long, folded conversation.
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	agents = { fixture = { type = "acp", cmd = { "false" } } },
})
local sessions = require("aero.session")
local s = sessions.create(vim.fn.getcwd(), "fixture")
assert(sessions.start(s, api.nvim_get_current_win(), true, nil, { history_only = true }))
local chat = s.chat
chat.busy = true
chat.doing = { kind = "writing" }
chat.blocks = {}
for turn = 1, 60 do
	table.insert(chat.blocks, { kind = "user", text = "Prompt " .. turn })
	table.insert(chat.blocks, { kind = "thought", text = "Inspect source\nChoose a fix" })
	for call = 1, 4 do
		table.insert(chat.blocks, {
			kind = "tool",
			id = turn .. ":" .. call,
			tool_kind = "read",
			status = "completed",
			title = "Read source",
			rawOutput = "first\nsecond\nthird",
		})
	end
	table.insert(chat.blocks, { kind = "agent", text = "Result " .. turn })
end
local function render()
	chat:render()
	assert(
		vim.wait(10000, function()
			return not chat.render_pending
		end, 1),
		"render timed out"
	)
end
render()
api.nvim_win_set_cursor(0, { 1, 0 })
local moves, original_cursor = 0, api.nvim_win_set_cursor
api.nvim_win_set_cursor = function(...)
	moves = moves + 1
	return original_cursor(...)
end
local start = vim.uv.hrtime()
local decodes, original_decode = 0, vim.json.decode
vim.json.decode = function(...)
	decodes = decodes + 1
	return original_decode(...)
end
for i = 1, 12 do
	chat.blocks[#chat.blocks].text = chat.blocks[#chat.blocks].text .. "\nStreamed line " .. i
	render()
end
local elapsed = (vim.uv.hrtime() - start) / 1e6
api.nvim_win_set_cursor = original_cursor
vim.json.decode = original_decode
print(("Streaming 60 turns / 240 tools, 12 updates: %.1f ms, %d cursor operations"):format(elapsed, moves))
assert(moves == 0, "streaming text walked or rebuilt historical folds")
assert(decodes == 0, "streaming text reparsed historical tool output for todos")

local function section(kind, block)
	for _, value in ipairs(chat.sections) do
		if value.kind == kind and value.key == block then
			return value
		end
	end
	error("missing section")
end
local first_call = chat.blocks[3]
local first_group = section("tools", first_call)
assert(vim.fn.foldclosed(first_group.first) == first_group.first)
first_call.rawOutput = first_call.rawOutput .. "\nlate output\nmore late output"
render()
first_group = section("tools", first_call)
assert(vim.fn.foldclosedend(first_group.first) == first_group.last, "native fold did not extend with late output")

-- Growing a tool group recreates only overwritten boundaries and preserves
-- native open choices on its existing children.
local last_call = chat.blocks[#chat.blocks - 4]
api.nvim_win_set_cursor(0, { section("tools", last_call).first, 0 })
vim.cmd("normal! zo")
api.nvim_win_set_cursor(0, { section("tool", last_call).first, 0 })
vim.cmd("normal! zo")
local added = { kind = "tool", id = "new", title = "New call", status = "completed" }
table.insert(chat.blocks, #chat.blocks, added)
render()
assert(vim.fn.foldclosed(section("tools", last_call).first) == -1)
assert(vim.fn.foldclosed(section("tool", last_call).first) == -1, "new call reset an opened sibling")
assert(vim.fn.foldclosed(section("tool", added).first) == section("tool", added).first)

-- Updating a historical group must retain its closed turn and shift later
-- folds correctly, rather than resetting the conversation's fold tree.
local first_prompt = chat.blocks[1]
api.nvim_win_set_cursor(0, { section("turn", first_prompt).first, 0 })
vim.cmd("normal! zc")
table.insert(chat.blocks, 7, { kind = "tool", id = "late", title = "Late call", status = "completed" })
render()
assert(vim.fn.foldclosedend(section("turn", first_prompt).first) == section("turn", first_prompt).last)
assert(vim.fn.foldclosed(section("tool", added).first) == section("tool", added).first)

-- Duplicate updates must not clear/recreate decorations across the whole log.
chat.busy = false
render()
local decorations, original_extmark = 0, api.nvim_buf_set_extmark
api.nvim_buf_set_extmark = function(...)
	decorations = decorations + 1
	return original_extmark(...)
end
render()
api.nvim_buf_set_extmark = original_extmark
assert(decorations == 0, "unchanged transcript rebuilt all decorations")
-- Cached layouts must match a fresh build, including late protocol updates,
-- timestamps, changed line limits, and absolute decoration positions.
local renderer = require("aero.acp.render")
local function check_cached_layout()
	local lines, marks = renderer.build(chat)
	local fresh = vim.tbl_extend("force", chat, { blocks = vim.deepcopy(chat.blocks) })
	setmetatable(fresh, getmetatable(chat))
	local fresh_lines, fresh_marks = renderer.build(fresh)
	assert(vim.deep_equal(lines, fresh_lines), "cached tool text differs from fresh layout")
	assert(vim.deep_equal(marks, fresh_marks), "cached tool decorations differ from fresh layout")
end
check_cached_layout()
first_call.timestamp = os.time()
first_call.content = { { type = "content", content = { type = "text", text = "replacement output" } } }
first_call.status = "failed"
check_cached_layout()
require("aero.config").options.acp.max_tool_lines = 1
check_cached_layout()
sessions.delete(s)
vim.fn.delete(dir, "rf")
vim.cmd("qa!")
