-- Permission presentation and buffer mappings; policy and responses live in permissions.lua.
local api = vim.api
local editor = require("aero.acp.editor_state").get
local M = {}

function M.pending(chat)
	chat:set_option_keys(chat.permission ~= nil)
	editor(chat).pending_focus = chat.permission ~= nil
end

function M.answered(chat)
	for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
		api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(chat.buf), 0 })
	end

	chat:changed()
end

function M.requested(chat, block)
	require("aero.inbox").add(chat, "permission", block)
	chat:set_option_keys(true)
	chat:advance(true)
	editor(chat).pending_focus = true
	chat:changed()

	if api.nvim_get_current_buf() ~= chat.buf then
		vim.notify(
			("Aero: %s in %s needs permission: %s (choose in the agent log, or :Aero prompt)"):format(
				chat.s.name,
				vim.fn.fnamemodify(chat.s.worktree, ":~"),
				block.title
			)
		)
	end
end

function M.set_option_keys(chat, on)
	for index = 1, 9 do
		local lhs = tostring(index)
		local available = false

		for _, request in ipairs(chat.permissions or {}) do
			available = available or request.block.options[index] ~= nil
		end

		if on and available then
			vim.keymap.set("n", lhs, function()
				local option = (editor(chat).option_lines or {})[api.nvim_win_get_cursor(0)[1]]
				chat:choose(index, option and option.block)
			end, { buffer = chat.buf, nowait = true, desc = "Aero: choose permission option " .. index })
		else
			pcall(vim.keymap.del, "n", lhs, { buffer = chat.buf })
		end
	end
end

return M
