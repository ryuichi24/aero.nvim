-- Run from the repository root: python3 tests/run.py --unit session_monitor
vim.opt.rtp:prepend(vim.fn.getcwd())
local config = require("aero.config")
config.options.notify_idle = true
local timers, notifications = {}, {}
local spins, changes, polls = 0, 0, 0
local new_timer = vim.uv.new_timer
vim.uv.new_timer = function()
	local timer = { stops = 0, closes = 0 }

	function timer:start(_, _, callback)
		self.callback = callback
	end

	function timer:stop()
		self.stops = self.stops + 1
	end

	function timer:close()
		self.closes = self.closes + 1
	end

	table.insert(timers, timer)
	return timer
end
require("aero.spinner").ensure = function()
	spins = spins + 1
end
vim.notify = function(message)
	table.insert(notifications, message)
end
local hidden = vim.api.nvim_create_buf(false, true)
local visible = vim.api.nvim_get_current_buf()
local first = { name = "Hidden", worktree = "/project", buf = hidden, current = "busy", running = true }
local second = { name = "Visible", worktree = "/project", buf = visible, current = "busy", running = true }
local runtime = { first, second }
local monitor = require("aero.session.monitor").new({
	sessions = function()
		polls = polls + 1
		return runtime
	end,
	status = function(s)
		return s.current
	end,
	running = function(s)
		return s.running
	end,
	changed = function()
		changes = changes + 1
	end,
})
local function tick(timer)
	timer.callback()
	vim.wait(10)
end

assert(#timers == 0, "constructing a monitor must not start polling")

monitor.ensure()
monitor.ensure()

assert(#timers == 1, "repeated startup must share one timer")

tick(timers[1])

assert(first.status == "busy" and second.status == "busy")
assert(changes == 1 and spins == 2, "a poll must coalesce status changes and activate busy spinners")

tick(timers[1])

assert(changes == 1 and spins == 4, "unchanged status must not emit a change")

first.current, second.current = "idle", "idle"
tick(timers[1])

assert(changes == 2 and #notifications == 1)
assert(notifications[1] == "aero: Hidden in /project is done", "only hidden busy-to-idle sessions should notify")
assert(timers[1].closes == 0, "idle but running sessions still require monitoring")

tick(timers[1])

assert(#notifications == 1, "idle notification repeated without a transition")

config.options.notify_idle = false
first.current = "busy"
tick(timers[1])
first.current = "idle"
tick(timers[1])

assert(#notifications == 1, "disabled notifications must stay silent")

config.options.notify_idle = true
first.buf, first.current = nil, "busy"
tick(timers[1])
first.current = "idle"
tick(timers[1])

assert(#notifications == 1, "sessions without a buffer must not notify")

second.current = "waiting"
tick(timers[1])

assert(second.status == "waiting" and timers[1].closes == 0)

first.current, second.current = "exited", "stopped"
first.running, second.running = false, false
tick(timers[1])

assert(timers[1].stops == 1 and timers[1].closes == 1, "the last stopped session must release the timer")

monitor.ensure()
local previous_polls = polls
timers[2].callback()
monitor.stop()
monitor.stop()
monitor.ensure()
vim.wait(10)

assert(polls == previous_polls, "a queued callback from an old timer must not poll the restarted lifetime")
assert(#timers == 3 and timers[2].closes == 1, "disposal must be idempotent and allow restart")

runtime = {}
tick(timers[3])

assert(timers[3].closes == 1, "polling must query the current registry and stop when it is empty")

vim.uv.new_timer = new_timer
print("Session monitor tests passed.")
