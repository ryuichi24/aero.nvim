-- Show a session and append to its draft without submitting.
local api = vim.api
local M = {}
function M.append(s, instruction, shown_win)
	local sessions = require("aero.session")
	if not vim.tbl_contains(sessions.all(), s) then
		return nil, "session no longer exists"
	end
	local panel, win = require("aero.panel"), shown_win
	if win then
		-- Caller already selected the session's window.
	elseif panel.enabled() then
		win = panel.show(s)
	else
		for _, candidate in ipairs(api.nvim_tabpage_list_wins(0)) do
			if api.nvim_win_get_buf(candidate) == s.buf then
				win = candidate
				break
			end
		end
		win = win or api.nvim_open_win(api.nvim_create_buf(false, true), false, { split = "right" })
		win = sessions.show(s, win, false)
	end
	if not win or not vim.tbl_contains(sessions.all(), s) then
		return nil, "session could not be shown"
	end
	if s.chat then
		local buf = s.chat:get_prompt_buf()
		local draft = api.nvim_buf_get_lines(buf, 0, -1, false)
		if #draft == 1 and draft[1] == "" then
			draft = {}
		elseif draft[#draft] ~= "" then
			table.insert(draft, "")
		end
		vim.list_extend(draft, vim.split(instruction, "\n", { plain = true }))
		table.insert(draft, "")
		api.nvim_buf_set_lines(buf, 0, -1, false, draft)
		s.chat:compose()
		api.nvim_win_set_cursor(0, { #draft, 0 })
		if not require("aero.config").options.start_insert then
			vim.cmd.stopinsert()
		end
	elseif s.job then
		api.nvim_set_current_win(win)
		vim.fn.chansend(s.job, "\027[200~" .. instruction .. "\n\027[201~")
		if require("aero.config").options.start_insert then
			vim.cmd.startinsert()
		end
	else
		return nil, "session is not running"
	end
	return true
end
return M
