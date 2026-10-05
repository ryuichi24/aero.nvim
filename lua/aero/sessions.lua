-- Live active sessions grouped by worktree.
local M = {}
local session = require("aero.session")
local picker = require("aero.picker")

local function label(s)
	local status = session.status(s)
	local activity = session.activity(s)
	return ("  %s %s [%s]  %s%s"):format(
		session.icon(s) or "",
		s.name,
		s.agent,
		status,
		activity and activity ~= status and " · " .. activity or ""
	)
end

M.close = picker.close

function M.open()
	picker.open({
		title = "active sessions",
		filetype = "aero_sessions",
		live = true,
		items = function()
			return vim.tbl_filter(session.is_running, session.all())
		end,
		label = label,
		group = function(s)
			return vim.fn.fnamemodify(s.worktree, ":~")
		end,
		search = function(s)
			return vim.fn.fnamemodify(s.worktree, ":~") .. " " .. label(s)
		end,
		sort = function(a, b)
			if a.worktree ~= b.worktree then
				return a.worktree < b.worktree
			end
			return a.name < b.name
		end,
		select = function(s)
			if not session.is_running(s) then
				vim.notify("Aero: session is no longer active", vim.log.levels.INFO)
				return
			end
			local win = require("aero").open_worktree(s.worktree)
			local panel = require("aero.panel")
			if panel.enabled() then
				panel.focus(s)
			else
				win = session.show(s, win)
				if win then
					vim.api.nvim_set_current_win(win)
					if require("aero.config").options.start_insert then
						session.enter(s)
					end
				end
			end
		end,
	})
end

return M
