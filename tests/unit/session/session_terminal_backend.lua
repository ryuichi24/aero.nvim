-- Run from the repository root: python3 tests/run.py --unit session_terminal_backend
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local config = require("aero.config")
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	fullscreen_key = false,
	agents = {
		fixture = {
			cmd = function(s)
				return { "fixture", s.name }
			end,
			resume = { "fixture", "resume" },
		},
	},
})
local sessions = require("aero.session")
local selected = assert(sessions.create(root, "fixture", "Backend"))
local starts, exits, launches = 0, 0, {}
require("aero.events").on("session_started", function()
	starts = starts + 1
end)
require("aero.events").on("session_exited", function(event)
	exits = exits + 1

	assert(event.exit_code == 7 and event.type == "terminal")
end)
local jobstart, jobpid, jobstop = vim.fn.jobstart, vim.fn.jobpid, vim.fn.jobstop
vim.fn.jobstart = function(cmd, opts)
	table.insert(launches, { cmd = cmd, opts = opts })
	return 100 + #launches
end
vim.fn.jobpid = function(job)
	return job + 1000
end
vim.fn.jobstop = function() end

assert(sessions.start(selected, 0, false))
assert(vim.deep_equal(launches[1].cmd, { "fixture", "Backend" }))

local old = selected.buf

assert(sessions.start(selected, 0, true))
assert(vim.deep_equal(launches[2].cmd, { "fixture", "resume" }))
assert(not vim.api.nvim_buf_is_valid(old), "accepted replacement must dispose the old buffer")
assert(selected.job == 102 and starts == 2)

launches[1].opts.on_exit(101, 9)
vim.wait(20)

assert(selected.job == 102 and selected.exit_code == nil and exits == 0, "stale exit changed the replacement session")

launches[2].opts.on_exit(102, 7)

assert(vim.wait(1000, function()
	return exits == 1
end))
assert(selected.job == nil and selected.exit_code == 7 and selected.status == "exited")
assert(vim.api.nvim_buf_is_valid(selected.buf), "exit must retain readable scrollback")

old = selected.buf
local notify, failure = vim.notify, nil
vim.notify = function(message)
	failure = message
end
vim.fn.jobstart = function()
	return -1
end

assert(not sessions.start(selected, 0, true))
assert(selected.buf == old and vim.api.nvim_buf_is_valid(old), "failed launch discarded the previous buffer")
assert(starts == 2 and exits == 1, "failed launch emitted lifecycle success events")
assert(failure:find("failed to start fixture resume", 1, true))

vim.notify = notify
vim.fn.jobstart, vim.fn.jobpid, vim.fn.jobstop = jobstart, jobpid, jobstop
config.options.persist_sessions = false
sessions.delete(selected)
vim.fn.delete(root, "rf")
print("Terminal backend lifecycle tests passed.")
