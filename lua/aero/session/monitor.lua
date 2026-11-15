-- One polling lifetime for a session registry, independent of backend and buffer ownership.
local config = require("aero.config")
local spinner = require("aero.spinner")
local M = {}

local function notify_idle(session)
	if config.options.notify_idle and session.buf and vim.fn.bufwinid(session.buf) == -1 then
		vim.notify(
			("aero: %s in %s is done"):format(session.name, vim.fn.fnamemodify(session.worktree, ":~")),
			vim.log.levels.INFO
		)
	end
end

--- Callbacks query current runtime sessions/status; the monitor owns only its polling timer.
function M.new(callbacks)
	local timer
	local monitor = {}

	function monitor.stop()
		if timer then
			timer:stop()
			timer:close()
			timer = nil
		end
	end

	local function tick()
		local changed, any = false, false

		for _, session in pairs(callbacks.sessions()) do
			local status = callbacks.status(session)
			any = any or callbacks.running(session)

			if status ~= session.status then
				if session.status == "busy" and status == "idle" then
					notify_idle(session)
				end

				session.status, changed = status, true
			end

			if status == "busy" then
				spinner.ensure()
			end
		end

		if changed then
			callbacks.changed()
		end

		if not any then
			monitor.stop()
		end
	end

	function monitor.ensure()
		if timer then
			return
		end

		timer = vim.uv.new_timer()
		local current = timer
		timer:start(
			300,
			300,
			vim.schedule_wrap(function()
				-- A callback queued before stop/restart cannot poll a later timer's lifetime.
				if timer == current then
					tick()
				end
			end)
		)
	end

	return monitor
end

return M
