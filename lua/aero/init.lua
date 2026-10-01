local M = {}

local did_setup = false

function M.setup(opts)
	require("aero.config").setup(opts)
	require("aero.store").load()
	require("aero.dashboard").setup_highlights()
	did_setup = true
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

function M.pick()
	ensure().pick()
end

--- Toggle the agent panel.
function M.panel()
	ensure()
	require("aero.panel").toggle()
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

---@param path? string any path inside a git repository; prompts when omitted
function M.add_workspace(path)
	ensure().add_workspace(path)
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
