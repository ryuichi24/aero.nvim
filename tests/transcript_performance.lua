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

local cold_start = vim.uv.hrtime()
local cold_times, restore_cold = {}, {}

for _, entry in ipairs({
	{ api, "nvim_buf_set_lines", "buffer edit" },
	{ require("aero.acp.render"), "build", "build" },
	{ require("aero.acp.render"), "decorate", "decorate" },
	{ require("aero.acp.folds"), "apply", "folds" },
}) do
	local module, key, label = unpack(entry)
	local original = module[key]
	restore_cold[#restore_cold + 1] = function()
		module[key] = original
	end
	module[key] = function(...)
		local start = vim.uv.hrtime()
		local result = { original(...) }
		cold_times[label] = (cold_times[label] or 0) + (vim.uv.hrtime() - start) / 1e6
		return unpack(result)
	end
end

render()

for _, restore in ipairs(restore_cold) do
	restore()
end

print(("Initial 60-turn transcript: %.1f ms"):format((vim.uv.hrtime() - cold_start) / 1e6))
print(vim.inspect(cold_times))
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
local running = { kind = "tool", id = "running", title = "Long-running command", status = "in_progress" }
table.insert(chat.blocks, running)
render()
local tick = api.nvim_buf_get_changedtick(chat.buf)
local builds, original_build = 0, chat.build_lines
chat.build_lines = function(self)
	builds = builds + 1
	return original_build(self)
end
local transcript = require("aero.acp.transcript")
local spinner_ns = api.nvim_create_namespace("Aero.acp.spinners")

assert(#api.nvim_buf_get_extmarks(chat.buf, spinner_ns, 0, -1, {}) == 2, "running tool and footer need spinners")

local animation_marks, set_extmark = 0, api.nvim_buf_set_extmark
api.nvim_buf_set_extmark = function(buf, ns, ...)
	if buf == chat.buf and ns == spinner_ns then
		animation_marks = animation_marks + 1
	end

	return set_extmark(buf, ns, ...)
end
require("aero.config").options.animation = true
require("aero.spinner").ensure()
vim.wait(300, function()
	return false
end, 10)
require("aero.config").options.animation = false
api.nvim_buf_set_extmark = set_extmark

assert(animation_marks > 0, "the shared clock must animate the transcript")
assert(builds == 0, "spinner frames must not rebuild historical transcript content")
assert(api.nvim_buf_get_changedtick(chat.buf) == tick, "animation must not trigger buffer-change listeners")

local original_activity = chat.activity
chat.activity = function()
	return "working · 2m 05s"
end
transcript.spin(chat)
local elapsed_visible = false

for _, mark in ipairs(api.nvim_buf_get_extmarks(chat.buf, spinner_ns, 0, -1, { details = true })) do
	if mark[4].virt_text[1][1]:find("2m 05s", 1, true) then
		elapsed_visible = true
	end
end

assert(elapsed_visible, "the display-only footer must keep elapsed time current")
assert(api.nvim_buf_get_changedtick(chat.buf) == tick)

chat.activity = original_activity
local spin_start = vim.uv.hrtime()

for _ = 1, 120 do
	transcript.spin(chat)
end

print(
	("120 display-only spinner frames: %.2f ms, %d transcript rebuilds"):format(
		(vim.uv.hrtime() - spin_start) / 1e6,
		builds
	)
)
chat.build_lines = original_build
running.status = "completed"
chat.busy = false
render()

assert(#api.nvim_buf_get_extmarks(chat.buf, spinner_ns, 0, -1, {}) == 0, "completed spinners must be cleared")

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
