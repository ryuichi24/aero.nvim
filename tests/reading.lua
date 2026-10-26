vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
vim.env.XDG_DATA_HOME = root .. "/data"
vim.fn.writefile({ "entry", "dispatch", "result" }, root .. "/source.lua")
local reading = require("aero.reading")
local binding = { worktree = root, session_key = "test-session" }
local args = {
	title = "Entry to result",
	items = {
		{ id = "entry", path = "source.lua", lnum = 1, label = "Entry", note = "Start here" },
		{ id = "result", path = "source.lua", lnum = 3, label = "Result" },
	},
}
local result = assert(reading.publish(binding, args))
assert(#reading.load(root, result.id).items == 2)
vim.fn.setqflist({}, " ", { title = "Existing search", items = { { filename = root .. "/source.lua", lnum = 2 } } })
local previous = vim.fn.getqflist({ id = 0 }).id
vim.t.aero_worktree = root
require("aero.config").setup({
	companion = { auto_start = false },
	reading = { explanation = { position = "below" } },
})
local reader = require("aero.reader")
reader.setup()
local source_win = vim.api.nvim_get_current_win()
local source_buf = vim.api.nvim_get_current_buf()
reader.attach(source_win)
local panel = require("aero.panel")
local agent_win = panel.open()
local agent_buf = vim.api.nvim_win_get_buf(agent_win)
vim.api.nvim_set_current_win(agent_win)
vim.ui.select = function(items, _, callback)
	callback(items[1])
end
reading.command()
local qf = vim.fn.getqflist({ id = 0, items = 0, context = 0 })
assert(qf.id ~= previous and #qf.items == 2)
assert(qf.items[1].text == "[ ] Entry")
local qf_win = vim.api.nvim_get_current_win()
local qf_height = vim.api.nvim_win_get_height(qf_win)
local grow_qf = vim.fn.maparg("<C-w>k", "n", false, true)
assert(type(grow_qf.callback) == "function", "reading quickfix must have shared resize controls")
grow_qf.callback()
assert(vim.api.nvim_win_get_height(qf_win) == qf_height + 1)
vim.fn.maparg("k", "n", false, true).callback()
assert(vim.api.nvim_win_get_height(qf_win) == qf_height + 2, "quickfix supports repeat resizing")
vim.fn.maparg("j", "n", false, true).callback()
assert(vim.api.nvim_win_get_height(qf_win) == qf_height + 1)
vim.api.nvim_exec_autocmds("WinLeave", {})
assert(vim.fn.maparg("j", "n", false, true).callback == nil, "leaving resize mode restores quickfix navigation")
assert(type(vim.fn.maparg("x", "n", false, true).callback) == "function", "read-progress mapping is preserved")
assert(type(vim.fn.maparg("K", "n", false, true).callback) == "function", "explanation mapping is preserved")
local note_win = vim.t.aero_reading_note_win
assert(vim.api.nvim_win_is_valid(note_win), "opening a list shows its explanation pane")
local note_buf = vim.api.nvim_win_get_buf(note_win)
local function note_text()
	return table.concat(vim.api.nvim_buf_get_lines(note_buf, 0, -1, false), "\n")
end
assert(note_text():find("Start here", 1, true))
vim.api.nvim_set_current_win(note_win)
vim.cmd.cnext()
assert(vim.api.nvim_win_get_buf(note_win) == note_buf, "cnext must not replace the explanation buffer")
assert(vim.api.nvim_get_current_win() ~= note_win, "native quickfix jumps must leave the explanation pane")
assert(vim.api.nvim_get_current_line() == "result", "native jump must preserve source contents")
assert(not vim.bo.modified, "refresh must not modify the source buffer")
assert(note_text():find("# Result", 1, true))
vim.api.nvim_set_current_win(note_win)
vim.cmd.cprevious()
assert(vim.api.nvim_win_get_buf(note_win) == note_buf, "cprev must not replace the explanation buffer")
assert(vim.api.nvim_get_current_line() == "entry")
assert(not vim.bo.modified)
assert(note_text():find("Start here", 1, true))
vim.api.nvim_set_current_win(qf_win)
vim.api.nvim_win_set_cursor(qf_win, { 2, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
assert(note_text():find("# Result", 1, true), "explanation follows quickfix cursor before jumping")
assert(note_text():find("No explanation was provided", 1, true))
vim.api.nvim_win_set_cursor(qf_win, { 1, 0 })
vim.api.nvim_exec_autocmds("CursorMoved", {})
vim.fn.maparg("<CR>", "n", false, true).callback()
assert(reader.active() == "reading")
assert(vim.api.nvim_get_current_win() == source_win)
assert(vim.uv.fs_realpath(vim.api.nvim_buf_get_name(0)) == vim.uv.fs_realpath(root .. "/source.lua"))
assert(vim.api.nvim_win_get_buf(agent_win) == agent_buf, "jump must preserve the agent panel")
reader.select("source")
assert(vim.api.nvim_get_current_buf() == source_buf, "jump must preserve the Source slot")
vim.api.nvim_set_current_win(qf_win)
reading.command("toggle")
assert(reading.load(root, result.id).items[1].read)
args.id = result.id
args.items[1].label = "Updated entry"
args.items[1].note = "Updated explanation"
assert(reading.publish(binding, args))
assert(note_text():find("Updated explanation", 1, true), "republishing refreshes the visible explanation")
assert(vim.fn.getqflist()[1].text == "[x] Updated entry")
assert(not reading.load(root, result.id).items[2].read)
reading.command("next")
assert(vim.fn.line(".") == 3)
assert(reader.active() == "reading")
assert(vim.api.nvim_win_get_buf(agent_win) == agent_buf)
assert(note_text():find("# Result", 1, true), "next refreshes the explanation")
vim.api.nvim_win_close(note_win, true)
reading.command("note")
assert(vim.api.nvim_win_is_valid(vim.t.aero_reading_note_win), "note reopens a closed pane")
assert(not reading.load(root, result.id).items[2].read, "navigation must not mark read")
local reading_buf = vim.api.nvim_get_current_buf()
reading.command("source")
assert(reader.active() == "source")
assert(vim.api.nvim_get_current_buf() == reading_buf)
assert(vim.fn.line(".") == 3)
assert(vim.api.nvim_win_get_buf(agent_win) == agent_buf)
reader.select("reading")
assert(vim.api.nvim_get_current_buf() == reading_buf)
assert(vim.fn.line(".") == 3)
assert(not reading.load(root, result.id).items[2].read)
reading.command("note-toggle")
assert(not vim.api.nvim_win_is_valid(vim.t.aero_reading_note_win), "toggle closes the explanation")
require("aero.config").options.reading.explanation.auto_open = false
reading.open(root, result.id)
assert(not vim.api.nvim_win_is_valid(vim.t.aero_reading_note_win), "auto_open=false keeps the pane closed")
reading.command("note-toggle")
assert(vim.api.nvim_win_is_valid(vim.t.aero_reading_note_win), "toggle opens with auto_open disabled")
reading.command("note-toggle")
reading.command("next")
assert(not vim.api.nvim_win_is_valid(vim.t.aero_reading_note_win), "navigation preserves temporary dismissal")
require("aero.config").options.reading.explanation.auto_open = true
reading.open(root, result.id)
assert(vim.api.nvim_win_is_valid(vim.t.aero_reading_note_win), "auto_open=true opens the pane")
panel.close()
local explanation_win = vim.t.aero_reading_note_win
local explanation_buf = vim.api.nvim_win_get_buf(explanation_win)
local reopened_panel = panel.open()
assert(vim.api.nvim_win_is_valid(explanation_win), "opening the agent panel preserves the explanation window")
assert(vim.api.nvim_win_get_buf(explanation_win) == explanation_buf)
assert(
	vim.api.nvim_win_get_width(explanation_win) == vim.api.nvim_win_get_width(source_win),
	"explanation shares the reader column instead of competing with the agent panel"
)
local explanation_pos = vim.api.nvim_win_get_position(explanation_win)
local reader_pos = vim.api.nvim_win_get_position(source_win)
assert(explanation_pos[2] == reader_pos[2] and explanation_pos[1] > reader_pos[1])
assert(reopened_panel ~= explanation_win)
-- Both placements must survive either opening order, including a narrow screen
-- where the agent's preferred width cannot fit alongside two reader columns.
local options = require("aero.config").options
options.layout.min_code_width = 20
options.panel.width = 60
for _, position in ipairs({ "below", "right" }) do
	options.reading.explanation.position = position
	for _, panel_first in ipairs({ false, true }) do
		reading.command("note-toggle")
		panel.close()
		vim.o.columns = 80
		if panel_first then
			panel.open()
		end
		reading.open(root, result.id)
		local note = vim.t.aero_reading_note_win
		local buf = vim.api.nvim_win_get_buf(note)
		local agent = panel.open()
		vim.api.nvim_set_current_win(note)
		local dimension = position == "right" and vim.api.nvim_win_get_width or vim.api.nvim_win_get_height
		local before = dimension(note)
		local key = position == "right" and "<C-w>h" or "<C-w>j"
		local resize = vim.fn.maparg(key, "n", false, true)
		assert(type(resize.callback) == "function", "explanation must have shared resize shortcuts")
		resize.callback()
		assert(dimension(note) == before - 1, "shared shortcut resizes the explanation")
		local repeat_key = position == "right" and "h" or "j"
		vim.fn.maparg(repeat_key, "n", false, true).callback()
		assert(dimension(note) == before - 2, "explanation supports repeat resizing")
		vim.api.nvim_set_current_win(source_win)
		for _, columns in ipairs({ 80, 70, 80 }) do
			vim.o.columns = columns
			require("aero.layout").rebalance()
			assert(vim.api.nvim_win_get_buf(note) == buf, "agent panel must preserve explanation contents")
			assert(vim.api.nvim_win_get_width(note) >= 20, "explanation must remain readable")
			assert(vim.api.nvim_win_get_width(source_win) >= 20, "reader must remain readable")
			local np = vim.api.nvim_win_get_position(note)
			local rp = vim.api.nvim_win_get_position(source_win)
			local ap = vim.api.nvim_win_get_position(agent)
			if position == "right" then
				assert(np[1] == rp[1] and np[2] > rp[2], "right placement must be beside the reader")
			else
				assert(np[2] == rp[2] and np[1] > rp[1], "below placement must share the reader column")
			end
			assert(ap[2] >= np[2] + vim.api.nvim_win_get_width(note), "agent must not overlap the explanation")
		end
	end
end
local replaced_note = vim.t.aero_reading_note_win
local source_file_buf = vim.fn.bufnr(root .. "/source.lua")
vim.wo[replaced_note].winfixbuf = false
vim.api.nvim_win_set_buf(replaced_note, source_file_buf)
vim.api.nvim_exec_autocmds("BufEnter", {})
assert(vim.t.aero_reading_note_win == nil, "replaced explanation windows must be detached")
assert(not vim.w[replaced_note].aero_reading_note)
assert(
	vim.deep_equal(vim.api.nvim_buf_get_lines(source_file_buf, 0, -1, false), { "entry", "dispatch", "result" }),
	"refresh must never write explanation text into a replacement source buffer"
)
assert(not vim.bo[source_file_buf].modified)
local invalid = vim.deepcopy(args)
invalid.items[1].path = "../outside.lua"
assert(not reading.publish(binding, invalid))
invalid = vim.deepcopy(args)
invalid.items[2].id = "entry"
assert(not reading.publish(binding, invalid))
assert(not reading.publish({ worktree = root, session_key = "other" }, args))
assert(reading.load(root, result.id).items[1].label == "Updated entry")

local executable = vim.env.AERO_MCP_EXECUTABLE
if executable then
	local config = require("aero.config").options
	config.reading.agent = { enabled = true, executable = executable }
	local agent = require("aero.reading_agent")
	local session = { key = binding.session_key, worktree = root, mcp_servers = { { name = "custom" } } }
	assert(agent.attach(session))
	assert(#session.mcp_servers == 2 and session.mcp_servers[2].name == "aero-reading")
	assert(agent.attach(session))
	assert(#session.mcp_servers == 2)
	agent.detach(session)
	assert(#session.mcp_servers == 1 and not session.reading_transport)
	local bridge = require("aero.tasks.bridge")
	local transport = assert(bridge.bind({ worktree = root, session_key = binding.session_key, reading_only = true }))
	local function call(method, params)
		local response
		vim.system(
			{ executable, "call", "--socket", transport.socket, method, vim.json.encode(params or {}) },
			{ text = true, env = { AERO_TASK_CREDENTIAL = transport.credential } },
			function(value)
				response = value
			end
		)
		assert(vim.wait(10000, function()
			return response ~= nil
		end))
		return response
	end
	assert(call("reading_list_publish", args).code == 0)
	assert(call("list_boards").code ~= 0)
	bridge.unbind(transport.credential)
	assert(call("reading_list_publish", args).code ~= 0)
	bridge.stop()
end
vim.fn.delete(root, "rf")
print("reading: ok")
vim.cmd.qa({ bang = true })
