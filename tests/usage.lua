-- Run from the repository root: nvim --headless -u NONE -l tests/usage.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local phase = vim.env.AERO_USAGE_PHASE
if not phase then
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	for _, step in ipairs({ "save", "load", "failure", "new" }) do
		local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", "tests/usage.lua" }, {
			env = { AERO_USAGE_PHASE = step, AERO_USAGE_STATE = dir .. "/state.json" }, text = true,
		}):wait(15000)
		assert(result.code == 0, step .. ": " .. (result.stderr or "") .. (result.stdout or ""))
	end
	vim.fn.delete(dir, "rf")
	print("Usage tests passed (tokens, cumulative fees, context, formatting, UI, restart, failed recovery, new conversations).")
	return
end
local api = vim.api
local aero = require("aero")
aero.setup({
	state_file = vim.env.AERO_USAGE_STATE, animation = false, start_insert = false,
	agents = { fixture = { type = "acp", cmd = { "python3", "tests/fixtures/usage.py", phase } } },
})
vim.cmd.runtime("plugin/aero.lua")
local usage = require("aero.acp.usage")
local sessions, history, store = require("aero.session"), require("aero.history"), require("aero.store")
local panel, config = require("aero.panel"), require("aero.config")
local cwd = vim.fn.getcwd()
local function wait(fn) assert(vim.wait(5000, fn, 10), "timed out") end
local function text(s) return table.concat(api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n") end
local s = phase == "save" and sessions.create(cwd, "fixture") or sessions.list(cwd)[1]
assert(s)
local old_notify, notification = vim.notify
vim.notify = function(message) notification = message end
if phase == "load" then
	-- Persisted metrics are available from a selected session without launching its agent.
	store.add_workspace(cwd)
	aero.open()
	for row, line in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
		if line:find(" " .. s.name, 1, true) then api.nvim_win_set_cursor(0, { row, 0 }); break end
	end
	local data = aero.usage()
	assert(not s.chat and data.tokens.totalTokens == 1860 and data.cost.amount == 0.02)
	assert(notification:find("Usage for " .. s.name, 1, true))
	aero.close()
end
if phase == "new" then
	assert(sessions.start(s, panel.open(), false))
	panel.shown(s)
else
	assert(panel.show(s))
end
api.nvim_set_current_win(panel.win())
wait(function() return s.chat.state == "ready" end)
local chat = s.chat
local function prompt(value, responses)
	chat:prompt(value)
	wait(function() return not chat.busy and chat.usage and chat.usage.tokens and chat.usage.tokens.responses == responses end)
end
if phase == "save" then
	assert(chat.usage == nil)
	vim.cmd("Aero usage")
	assert(notification:find("not reported", 1, true), "unknown usage was presented as zero")
	prompt("first question", 1)
	assert(chat.usage.tokens.totalTokens == 1600 and chat.usage.cost.amount == 0.0125)
	prompt("second question", 2)
	local data = chat.usage
	assert(data.tokens.totalTokens == 1860 and data.tokens.inputTokens == 1400 and data.tokens.outputTokens == 340)
	assert(data.tokens.thoughtTokens == 60 and data.tokens.cachedReadTokens == 50 and data.tokens.cachedWriteTokens == 10)
	assert(data.cost.amount == 0.02, "cumulative fees were added instead of replaced")
	assert(data.context.used == 3000, "context snapshots were summed or compaction was ignored")
	wait(function() return text(s):find("Total fee (last reported): USD 0.02", 1, true) end)
	assert(text(s):find("Tokens (reported turns): 1,860", 1, true))
	assert(text(s):find("Context: 3,000 / 10,000 tokens (30.0%)", 1, true))
	assert(vim.wo[panel.win()].winbar:find("1.9k tracked tok", 1, true))
	assert(vim.wo[panel.win()].winbar:find("USD 0.02", 1, true))
	store.add_workspace(cwd)
	aero.open()
	local found
	for _, mark in ipairs(api.nvim_buf_get_extmarks(0, api.nvim_create_namespace("Aero"), 0, -1, { details = true })) do
		for _, part in ipairs(mark[4].virt_text or {}) do
			if part[1]:find("1.9k tracked tok", 1, true) and part[1]:find("USD 0.02", 1, true) then found = true end
		end
	end
	assert(found, "dashboard session rows do not show usage")
	api.nvim_set_current_win(panel.win())
	local data_copy = aero.usage()
	data_copy.cost.amount = 999
	assert(chat.usage.cost.amount == 0.02, "the usage API exposed mutable session state")
	config.options.acp.show_usage = false
	chat:changed()
	wait(function() return not text(s):find("### Usage", 1, true) end)
	assert(not vim.wo[panel.win()].winbar:find("tracked tok", 1, true))
	assert(usage.summary(chat) == nil and chat.usage.tokens.totalTokens == 1860)
	config.options.acp.show_usage = true
elseif phase == "load" then
	assert(chat.usage.tokens.totalTokens == 1860 and chat.usage.tokens.responses == 2, "load replay doubled token usage")
	assert(chat.usage.cost.amount == 0.02)
	prompt("third question", 3)
	assert(chat.usage.tokens.totalTokens == 2120 and chat.usage.cost.amount == 0.03)
elseif phase == "failure" then
	assert(chat.usage.tokens.totalTokens == 2120 and chat.usage.cost.amount == 0.03)
	vim.cmd("Aero resume broken-usage")
	wait(function() return s.chat.resume_error ~= nil end)
	chat = s.chat
	assert(chat.usage.tokens.totalTokens == 2120 and chat.usage.cost.amount == 0.03,
		"a failed replacement conversation contaminated the previous usage")
	assert(store.find_session(s.worktree, s.name).acp_session_id == "usage-session")
else
	assert(chat.session_id == "new-usage-session" and chat.usage == nil, "a new conversation inherited old usage")
	prompt("new question", 1)
	assert(chat.usage.tokens.totalTokens == 1600 and chat.usage.cost.amount == 0.0125)
end
history.flush(s)
local saved = history.load(s)
assert(saved.usage.tokens.totalTokens == chat.usage.tokens.totalTokens)

-- Missing/invalid values, authoritative totals, zero fees, and duplicate response IDs.
local sample = {}
usage.update(sample, { used = 0, size = 0, cost = { amount = 0, currency = "USD" } })
assert(table.concat(usage.lines(sample), "\n"):find("USD 0.00", 1, true))
assert(not table.concat(usage.lines(sample), "\n"):find("nan", 1, true))
usage.update(sample, { used = -1, size = 100, cost = { amount = math.huge, currency = "USD" } })
assert(sample.usage.context.used == 0 and sample.usage.cost.amount == 0)
usage.response(sample, { usage = { inputTokens = 100, outputTokens = 50, totalTokens = 130 } }, 1)
usage.response(sample, { usage = { inputTokens = 100, outputTokens = 50, totalTokens = 130 } }, 1)
assert(sample.usage.tokens.totalTokens == 130 and sample.usage.tokens.responses == 1)
usage.response(sample, { usage = { inputTokens = 10, outputTokens = 5, cachedReadTokens = 100 } }, 2)
assert(sample.usage.tokens.totalTokens == 145, "fallback totals double-counted cache tokens")
usage.response(sample, { usage = { inputTokens = -1, outputTokens = 0 / 0, totalTokens = math.huge } }, 3)
assert(sample.usage.tokens.responses == 2, "invalid prompt usage was accumulated")
usage.update(sample, { cost = { amount = 0.000000001, currency = "JPY" } })
assert(usage.summary(sample):find("JPY", 1, true) and not usage.summary(sample):find("JPY 0.00", 1, true))
local restored = {}
usage.restore(restored, { tokens = { responses = -1 }, context = { used = 0 / 0, size = 100 }, cost = { amount = -1, currency = "USD" } })
assert(restored.usage == nil, "invalid saved metrics were accepted")
vim.notify = old_notify
