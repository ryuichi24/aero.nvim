-- Run from the repository root: nvim --headless -u NONE -l tests/persistence.lua
vim.opt.rtp:prepend(vim.fn.getcwd())

local phase = vim.env.AERO_HISTORY_PHASE
if not phase then
	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p")
	for _, step in ipairs({
		"save",
		"replay",
		"recover-id",
		"missing-id",
		"fail",
		"unsupported",
		"wipe",
		"delete",
		"disabled",
	}) do
		local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", "tests/persistence.lua" }, {
			env = { AERO_HISTORY_PHASE = step, AERO_HISTORY_STATE = dir .. "/state.json" },
			text = true,
		}):wait(15000)
		assert(result.code == 0, step .. ": " .. (result.stderr or "") .. (result.stdout or ""))
	end
	vim.fn.delete(dir, "rf")
	print("Persistence tests passed (separate Neovim processes).")
	return
end

local config = require("aero.config")
config.setup({
	state_file = vim.env.AERO_HISTORY_STATE,
	persist_sessions = phase ~= "disabled",
	animation = false,
	agents = {
		fixture = { type = "acp", cmd = { "python3", "tests/fixtures/acp.py", phase } },
		pty = {
			cmd = { "sh", "-c", "printf 'old terminal output\\n'; read line; printf 'input:%s\\n' \"$line\"; sleep 30" },
			resume = {
				"sh",
				"-c",
				"printf '\\033[H\\033[2Jnew terminal output\\n'; read line; printf 'input:%s\\n' \"$line\"; sleep 30",
			},
		},
	},
})
local store = require("aero.store")
local sessions = require("aero.session")
local history = require("aero.history")
local cwd = vim.fn.getcwd()
store.load()

local function wait(fn)
	assert(vim.wait(5000, fn, 10), "timed out")
end
local function text(s)
	return table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n")
end
local function contains(s, value)
	return text(s):find(value, 1, true) ~= nil
end
local function find(agent)
	for _, s in ipairs(sessions.list(cwd)) do
		if s.agent == agent then
			return s
		end
	end
	error("missing session: " .. agent)
end

if phase == "disabled" then
	local s = sessions.create(cwd, "pty")
	assert(sessions.show(s, 0))
	wait(function()
		return contains(s, "old terminal output")
	end)
	sessions.stop(s)
	assert(history.load(s) == nil)
	assert(#vim.fn.glob(config.options.state_file .. ".history/*.json", false, true) == 0)
	return
end

local acp = phase == "save" and sessions.create(cwd, "fixture") or find("fixture")
local pty = phase == "save" and sessions.create(cwd, "pty") or find("pty")
if phase == "delete" then
	sessions.delete(acp)
	sessions.delete(pty)
	vim.wait(600)
	assert(history.load(acp) == nil and history.load(pty) == nil)
	return
end

if phase == "recover-id" or phase == "missing-id" then
	store.set_session_field(acp.worktree, acp.name, "acp_session_id", nil)
	if phase == "missing-id" then
		local saved = history.load(acp)
		saved.session_id = nil
		history.save(acp, function()
			return saved
		end)
		history.flush(acp)
	end
end

assert(sessions.show(acp, 0))
if phase == "fail" then
	acp.chat:prompt("queued before load failed")
	wait(function()
		return acp.chat.resume_error ~= nil
	end)
	wait(function()
		return contains(acp, "fixture: failed to read saved rollout")
	end)
	assert(contains(acp, "code -32603") and contains(acp, "/fixture/rollout.jsonl"), "adapter details were hidden")
	assert(not sessions.is_running(acp), "failed resume remained busy")
	assert(
		store.find_session(acp.worktree, acp.name).acp_session_id == "fixture-session",
		"failed load replaced the original ID"
	)
	assert(history.load(acp).session_id == "fixture-session", "failed load lost the history session ID")
	local draft = acp.chat:get_prompt_buf()
	vim.api.nvim_buf_set_lines(draft, 0, -1, false, { "draft after load failure" })
	local notify = vim.notify
	vim.notify = function() end
	acp.chat:send_prompt_buf()
	vim.notify = notify
	assert(
		vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "draft after load failure",
		"failed backend discarded the draft"
	)
	-- Retry the same session once the fixture's transient error is removed.
	config.options.agents.fixture.cmd[3] = "replay"
	assert(sessions.start(acp, vim.api.nvim_get_current_win(), true))
	wait(function()
		return acp.chat.state == "ready" and not acp.chat.busy
	end)
	assert(acp.chat.resumed and #acp.chat.queue == 0, "retry did not resume and flush the queued prompt")
	assert(
		acp.chat.prompt_buf == draft
			and vim.api.nvim_buf_get_lines(draft, 0, -1, false)[1] == "draft after load failure"
	)
	wait(function()
		return contains(acp, "queued before load failed")
	end)
end
wait(function()
	return acp.chat.state == "ready"
end)
assert(sessions.from_buf(acp.buf) == acp, "ACP buffer uses a different session registry")
assert(store.find_session(acp.worktree, acp.name).acp_session_id == "fixture-session", "ACP ID was not persisted")
if phase == "save" then
	acp.chat:prompt("old question")
	wait(function()
		return not acp.chat.busy and contains(acp, "old answer")
	end)
else
	wait(function()
		return contains(acp, "old question") and contains(acp, "old answer")
	end)
	for _, value in ipairs({ "old thought", "old tool", "old tool output", "old plan" }) do
		assert(contains(acp, value), "missing saved ACP block: " .. value)
	end
	local _, count = text(acp):gsub("old answer", "")
	assert(count == 1, "replayed history duplicated")
	if phase == "fail" then
		wait(function()
			return contains(acp, "could not resume")
		end)
	end
	if phase == "unsupported" then
		wait(function()
			return contains(acp, "agent does not advertise session/load support")
		end)
	end
	if phase == "missing-id" then
		wait(function()
			return contains(acp, "no saved ACP session ID")
		end)
	elseif phase == "replay" or phase == "recover-id" then
		wait(function()
			return contains(acp, "resumed session")
		end)
	end
	acp.chat:prompt("new question")
	wait(function()
		return not acp.chat.busy and contains(acp, "new answer")
	end)
end

vim.cmd("vsplit")
local input
local open_term = vim.api.nvim_open_term
vim.api.nvim_open_term = function(buf, opts)
	input = opts.on_input
	return open_term(buf, opts)
end
assert(sessions.show(pty, 0))
vim.api.nvim_open_term = open_term
wait(function()
	return contains(pty, phase == "save" and "old terminal output" or "new terminal output")
end)
if phase ~= "save" then
	assert(contains(pty, "old terminal output"), "scrollback missing after restart")
	assert(contains(pty, "restored scrollback"))
end
-- Headless -l does not enter terminal mode; exercise its input callback directly.
input(nil, nil, nil, "hello\r")
wait(function()
	return contains(pty, "input:hello")
end)
vim.cmd.stopinsert()
vim.cmd("vertical resize 35")
vim.api.nvim_exec_autocmds("WinResized", {})
if phase == "wipe" then
	local job = pty.job
	vim.api.nvim_buf_delete(pty.buf, { force = true })
	local saved = history.load(pty)
	assert(saved and table.concat(saved.lines, "\n"):find("old terminal output", 1, true), "wiping lost scrollback")
	assert(vim.fn.jobwait({ job }, 1000)[1] ~= -1, "wiping left the PTY running")
end
-- Leave with debounced writes still pending: VimLeavePre must flush both snapshots.
