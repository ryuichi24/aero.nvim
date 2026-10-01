-- Run from the repository root: nvim --headless -u NONE -l tests/recovery.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local aero = require("aero")
aero.setup({
	state_file = dir .. "/state.json",
	animation = false,
	fullscreen_key = false,
	agents = { fixture = { type = "acp", cmd = { "python3", "tests/fixtures/acp.py", "missing-rollout" } } },
})
vim.cmd.runtime("plugin/aero.lua")
local sessions, store, history = require("aero.session"), require("aero.store"), require("aero.history")
local function wait(fn)
	assert(vim.wait(5000, fn, 10), "timed out")
end
local function text(s)
	return table.concat(api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n")
end
local s = sessions.create(vim.fn.getcwd(), "fixture")
store.set_session_field(s.worktree, s.name, "acp_session_id", "missing-session")
history.save(s, function()
	return { type = "acp", session_id = "missing-session", blocks = { { kind = "info", text = "old fallback error" } } }
end)
history.flush(s)
assert(sessions.start(s, api.nvim_get_current_win(), true))
wait(function()
	return s.chat.resume_error ~= nil
end)

require("aero.config").options.agents.fixture.cmd[3] = "recover"
vim.cmd("Aero resume recovered-session")
wait(function()
	return s.chat.state == "ready"
end)
wait(function()
	return text(s):find("recovered answer", 1, true)
end)
assert(s.chat.resumed and s.chat.session_id == "recovered-session")
assert(store.find_session(s.worktree, s.name).acp_session_id == "recovered-session")
assert(not text(s):find("old fallback error", 1, true), "old transcript was relabeled as the recovered conversation")
assert(text(s):find("recovered question", 1, true), "recovered user history was suppressed")

-- A failed explicit recovery keeps the currently saved conversation and its transcript.
require("aero.config").options.agents.fixture.cmd[3] = "recover-fail"
vim.cmd("Aero resume broken-recovery")
wait(function()
	return s.chat.resume_error ~= nil
end)
wait(function()
	return text(s):find("recovered answer", 1, true)
end)
assert(store.find_session(s.worktree, s.name).acp_session_id == "recovered-session")
assert(history.load(s).session_id == "recovered-session")

require("aero.config").options.agents.fixture.cmd[3] = "replay-recovered"
assert(sessions.start(s, api.nvim_get_current_win(), true))
wait(function()
	return s.chat.state == "ready"
end)
wait(function()
	return text(s):find("recovered answer", 1, true)
end)
local _, count = text(s):gsub("recovered answer", "")
assert(count == 1, "matching saved conversation was replayed twice")

-- Error-only logs must not suppress a successful replay, even for the same saved ID.
local errors_only = sessions.create(s.worktree, "fixture")
store.set_session_field(errors_only.worktree, errors_only.name, "acp_session_id", "recovered-session")
history.save(errors_only, function()
	return { type = "acp", session_id = "recovered-session", blocks = { { kind = "info", text = "previous error" } } }
end)
history.flush(errors_only)
assert(sessions.start(errors_only, api.nvim_get_current_win(), true))
wait(function()
	return errors_only.chat.state == "ready"
end)
wait(function()
	return text(errors_only):find("recovered answer", 1, true)
end)
assert(text(errors_only):find("recovered question", 1, true))

local stale = sessions.create(s.worktree, "fixture")
store.set_session_field(stale.worktree, stale.name, "acp_session_id", "recovered-session")
history.save(stale, function()
	return {
		type = "acp",
		session_id = "different-conversation",
		blocks = { { kind = "user", text = "wrong cached conversation" } },
	}
end)
history.flush(stale)
assert(sessions.start(stale, api.nvim_get_current_win(), true))
wait(function()
	return stale.chat.state == "ready"
end)
wait(function()
	return text(stale):find("recovered answer", 1, true)
end)
assert(
	not text(stale):find("wrong cached conversation", 1, true),
	"cache from a different ID contaminated the transcript"
)

-- Explicit recovery cannot silently create a replacement if loading is unsupported.
require("aero.config").options.agents.fixture.cmd[3] = "unsupported"
vim.cmd("Aero resume unsupported-choice")
wait(function()
	return stale.chat.resume_error ~= nil
end)
assert(store.find_session(stale.worktree, stale.name).acp_session_id == "recovered-session")
assert(history.load(stale).session_id == "recovered-session")

sessions.delete(stale)
sessions.delete(errors_only)
sessions.delete(s)
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print("Recovery tests passed (explicit ID, error-only replay, failed recovery preserves ID/log, duplicate prevention).")
