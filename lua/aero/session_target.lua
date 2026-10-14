-- Session selection policy, independent of dashboard rendering.
-- The dashboard supplies only its current selection; resolving never starts a session.
local api = vim.api
local session = require("aero.session")
local panel = require("aero.panel")
local M = {}
local dashboard_selection = function()
	return false, nil
end

function M.set_dashboard_selection(resolve)
	dashboard_selection = resolve
end

function M.from_buffer(buf)
	if buf == nil or buf == 0 then
		buf = api.nvim_get_current_buf()
	end
	local selected = session.from_buf(buf)
	local key = vim.b[buf].aero_chat_key
	if not selected and key then
		for _, candidate in ipairs(session.all()) do
			if candidate.key == key then
				return candidate
			end
		end
	end
	return selected
end

---@param policy "cancel"|"resume"|"viewed"
---@return aero.Session?
function M.resolve(policy)
	local selected = M.from_buffer(api.nvim_get_current_buf())
	if selected then
		return selected
	end
	local in_dashboard, item = dashboard_selection()
	if in_dashboard then
		selected = item and item.session
		if not selected and policy == "viewed" and item and item.wt then
			local current = panel.current_session()
			local candidates = session.list(item.wt.path)
			if current and current.worktree == item.wt.path then
				selected = current
			elseif #candidates == 1 then
				selected = candidates[1]
			end
		end
		-- Cancel/viewed deliberately do not fall back from an unrelated dashboard row.
		if selected or policy ~= "resume" then
			return selected
		end
	end
	if policy == "resume" then
		local win = panel.win()
		return win and session.from_buf(api.nvim_win_get_buf(win)) or nil
	end
	return panel.current_session()
end

return M
