-- Run from the repository root: python3 tests/run.py --unit session_startup
vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero").setup({
	state_file = root .. "/state.json",
	animation = false,
	agents = { fixture = { type = "acp", cmd = { "fixture" } } },
})
local sessions = require("aero.session")
local selected = assert(sessions.create(root, "fixture", "Startup"))
local started, changes, stops, forgotten = {}, 0, 0, 0
local notified_stop_state
local fail, launch_buf, launch_opts, launch_id, launch_resume
local active = false
package.loaded["aero.acp"] = {
	start = function(s, buf, agent, resume, session_id, opts)
		assert(s == selected and s.buf == buf, "ACP must receive the newly owned transcript buffer")
		assert(s.job == nil and s.exit_code == nil and s.fresh == false)
		assert(agent.type == "acp")

		launch_buf, launch_opts, launch_id, launch_resume = buf, opts, session_id, resume

		if fail then
			return nil
		end

		active = not opts.history_only
		return {
			alive = function()
				return active
			end,
			status = function()
				return active and "idle" or "stopped"
			end,
			stop = function()
				active = false
				stops = stops + 1
			end,
		}
	end,
	forget = function(s)
		assert(s == selected)

		forgotten = forgotten + 1
	end,
}
require("aero.session.integrations").prepare = function()
	return true
end
local unsubscribe = sessions.on_change(function()
	changes = changes + 1
	notified_stop_state = selected.stop_requested
end)
require("aero.events").on("session_started", function(event)
	table.insert(started, event)
end)

selected.stop_requested = true
local history_opts = { history_only = true }

assert(sessions.start(selected, nil, true, nil, history_opts))
assert(launch_opts == history_opts and launch_resume == true)
assert(changes == 1 and #started == 0, "history-only loading must publish a change without a startup event")
assert(notified_stop_state == false, "startup notification preceded stop-state reset")

local old = selected.buf
local resume_opts = { restore_tasks = false, on_resume = function() end }

assert(sessions.start(selected, nil, true, "conversation-id", resume_opts))
assert(launch_opts == resume_opts and launch_id == "conversation-id")
assert(not vim.api.nvim_buf_is_valid(old), "accepted backend must release the old transcript")
assert(changes == 2 and #started == 1)
assert(notified_stop_state == false)
assert(started[1].type == "acp" and started[1].resume == true and started[1].win == nil)

old, fail = selected.buf, true

assert(not sessions.start(selected, nil, true))
assert(not vim.api.nvim_buf_is_valid(launch_buf), "failed backend must discard the prepared transcript")
assert(vim.api.nvim_buf_is_valid(old), "failed backend must preserve the old transcript")
assert(selected.buf == nil and selected.chat == nil)
assert(changes == 2 and #started == 1, "failed backend must not finalize startup")

fail = false

assert(sessions.start(selected, nil, false))

unsubscribe()
local buf = selected.buf
vim.api.nvim_buf_delete(buf, { force = true })

assert(selected.buf == nil and selected.chat == nil, "accepted startup must install buffer wipe handling")
assert(stops >= 3)

assert(sessions.delete(selected))
assert(forgotten == 1)

vim.fn.delete(root, "rf")
print("Session startup finalization tests passed.")
