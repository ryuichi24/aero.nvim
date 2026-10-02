-- Optional real-agent smoke test: nvim --headless -u NONE -l tests/opencode.lua
-- Uses isolated OpenCode storage/configuration and sends no model prompts.
vim.opt.rtp:prepend(vim.fn.getcwd())
if vim.fn.executable("opencode") ~= 1 then
	print("OpenCode smoke test skipped: opencode is not installed.")
	return
end
local phase = vim.env.AERO_OPENCODE_PHASE
if not phase then
	local dir = vim.fn.tempname()
	for _, name in ipairs({ "workspace", "home", "data", "state", "cache", "config" }) do
		vim.fn.mkdir(dir .. "/" .. name, "p")
	end
	for _, step in ipairs({ "new", "resume", "terminal" }) do
		local result = vim.system(
			{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", "tests/opencode.lua" },
			{
				env = { AERO_OPENCODE_PHASE = step, AERO_OPENCODE_DIR = dir },
				text = true,
			}
		)
			:wait(60000)
		if result.code ~= 0 then
			vim.fn.delete(dir, "rf")
			error(step .. ": " .. (result.stderr or "") .. (result.stdout or ""))
		end
		local switched = ((result.stdout or "") .. (result.stderr or "")):match(
			"OpenCode model switch verified: ([^\n]+)"
		)
		if switched then
			print("OpenCode model switch verified: " .. switched)
		end
	end
	vim.fn.delete(dir, "rf")
	print("OpenCode smoke tests passed (real ACP new/load across processes, terminal start/continue).")
	return
end

local dir = vim.env.AERO_OPENCODE_DIR
local config = require("aero.config")
local env = {
	HOME = dir .. "/home",
	XDG_DATA_HOME = dir .. "/data",
	XDG_STATE_HOME = dir .. "/state",
	XDG_CACHE_HOME = dir .. "/cache",
	XDG_CONFIG_HOME = dir .. "/config",
	OPENCODE_DISABLE_AUTOUPDATE = "true",
	OPENCODE_DISABLE_DEFAULT_PLUGINS = "true",
}
local terminal, acp =
	vim.deepcopy(config.defaults.agents.opencode), vim.deepcopy(config.defaults.agents["opencode-acp"])
terminal.env, acp.env = env, env
require("aero").setup({
	state_file = dir .. "/aero.json",
	animation = false,
	fullscreen_key = false,
	agents = { opencode = terminal, ["opencode-acp"] = acp },
})
local sessions, store = require("aero.session"), require("aero.store")
local worktree = dir .. "/workspace"
local function wait(fn)
	assert(vim.wait(45000, fn, 20), "OpenCode startup timed out")
end

if phase == "terminal" then
	local s = sessions.create(worktree, "opencode")
	assert(sessions.show(s, 0))
	wait(function()
		return s.exit_code ~= nil
			or table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n"):match("%S") ~= nil
	end)
	assert(s.job and vim.fn.jobwait({ s.job }, 0)[1] == -1, "OpenCode TUI did not start")
	vim.fn.chansend(s.job, "\004") -- OpenCode's Ctrl-D exit path, not a forced job stop.
	wait(function()
		return s.exit_code ~= nil
	end)
	assert(sessions.start(s, vim.api.nvim_get_current_win(), true))
	vim.wait(1000)
	assert(s.job and vim.fn.jobwait({ s.job }, 0)[1] == -1, "OpenCode --continue failed")
	sessions.stop(s)
	wait(function()
		return s.exit_code ~= nil
	end)
	return
end

local s = phase == "new" and sessions.create(worktree, "opencode-acp") or sessions.list(worktree)[1]
assert(s and s.agent == "opencode-acp")
local previous = store.find_session(worktree, s.name).acp_session_id
assert(sessions.show(s, 0))
local done = vim.wait(45000, function()
	return s.chat.state == "ready" or s.chat.state == "exited"
end, 20)
if not done or s.chat.state ~= "ready" then
	local detail = table.concat(s.chat.client.stderr, "")
	local transcript = table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n")
	sessions.stop(s)
	error("OpenCode ACP failed: " .. transcript .. "\n" .. detail)
end
assert(s.chat.caps.loadSession, "OpenCode does not advertise session loading")
assert(type(s.chat.session_id) == "string" and s.chat.session_id ~= "")
if phase == "resume" then
	assert(s.chat.resumed and s.chat.session_id == previous, "OpenCode did not load the same persisted conversation")
end
local models = require("aero.acp.models")
local choices = models.options(s.chat).choices
assert(#choices > 0, "OpenCode did not expose models")
if phase == "new" then
	local current = models.current(s.chat)
	local alternative
	for _, choice in ipairs(choices) do
		if choice.id ~= current then
			alternative = choice
			break
		end
	end
	if alternative then
		s.chat:prompt("/model " .. alternative.id)
		wait(function()
			return not s.chat.model_pending
		end)
		assert(
			models.current(s.chat) == alternative.id,
			"OpenCode model switch failed: " .. table.concat(vim.api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n")
		)
		assert(s.chat.session_id == store.find_session(worktree, s.name).acp_session_id)
		print("OpenCode model switch verified: " .. current .. " -> " .. alternative.id)
	end
end
sessions.stop(s)
wait(function()
	return s.chat.client.closed
end)
