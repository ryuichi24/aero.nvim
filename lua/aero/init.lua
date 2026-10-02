local M = {}

local did_setup = false

function M.setup(opts)
	require("aero.config").setup(opts)
	require("aero.events").setup(require("aero.config").options.events)
	require("aero.fullscreen").setup()
	require("aero.store").load()
	require("aero.buffers").setup()
	require("aero.dashboard").setup_highlights()
	require("aero.dashboard").set_keymaps()
	require("aero.layout").setup()
	require("aero.quote").setup()
	did_setup = true
	require("aero.events").emit("setup", {})
end

--- Register a lifecycle handler. Returns an unsubscribe function.
function M.on(name, callback, opts)
	return require("aero.events").on(name, callback, opts)
end

function M.once(name, callback)
	return require("aero.events").once(name, callback)
end

function M.off(name, callback)
	require("aero.events").off(name, callback)
end

local function ensure()
	if not did_setup then
		M.setup()
	end
	return require("aero.dashboard")
end

function M.open()
	ensure().open()
end

function M.close()
	ensure().close()
end

function M.toggle()
	ensure().toggle()
end

function M.refresh()
	ensure().refresh()
end

--- Pull the selected worktree, current checkout, or an explicit path asynchronously.
function M.pull(path)
	return ensure().pull(path)
end

function M.pick()
	ensure().pick()
end

--- Reconnect the selected ACP session to an existing adapter conversation ID.
function M.resume(session_id)
	return ensure().resume(session_id)
end

--- Toggle the agent panel.
function M.panel()
	ensure()
	require("aero.panel").toggle()
end

--- Toggle fullscreen for the focused pane, including the code window.
function M.fullscreen()
	ensure()
	require("aero.fullscreen").toggle()
end

--- Toggle the current worktree's terminal below the code window.
function M.terminal()
	ensure().toggle_terminal()
end

--- Jump to the panel session's prompt (or terminal), opening the panel if needed.
function M.prompt()
	ensure()
	require("aero.panel").prompt()
end

--- Show usage for the selected agent and return its latest reported metrics, if any.
function M.usage()
	return ensure().usage()
end

--- Append the visual selection (or an explicit line range) to an agent's draft.
function M.quote(range)
	ensure()
	return require("aero.quote").quote(range)
end

---@param path? string any path inside a git repository; prompts when omitted
function M.add_workspace(path)
	ensure().add_workspace(path)
end

--- Focus a worktree's code window; optionally use a custom directory opener.
function M.open_worktree(path, opener)
	return ensure().open_worktree(path, opener)
end

--- Short summary for a statusline, e.g. "◐1 ●2"; empty when no session is running.
function M.statusline()
	if not did_setup then
		return ""
	end
	local session = require("aero.session")
	local icons = require("aero.config").options.icons
	local counts = {}
	for _, s in ipairs(session.all()) do
		local st = session.status(s)
		counts[st] = (counts[st] or 0) + 1
	end
	local out = {}
	for _, st in ipairs({ "waiting", "busy", "idle" }) do
		if counts[st] then
			table.insert(out, (st == "busy" and require("aero.spinner").frame() or icons[st]) .. counts[st])
		end
	end
	return table.concat(out, " ")
end

return M
