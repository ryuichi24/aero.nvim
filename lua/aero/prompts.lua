-- Prompt history is derived from the viewed conversation, never a global registry.
local M = {}
local api = vim.api

function M.items(chat)
	local items = {}
	for index, block in ipairs(chat.blocks) do
		if block.kind == "user" then
			table.insert(items, { key = tostring(index), block = block, text = block.text })
		end
	end
	return items
end

function M.open(chat)
	if not chat then
		local s = require("aero.dashboard").viewed_session()
		chat = s and s.chat
	end
	if not chat then
		vim.notify("Aero: focus an ACP session to view its prompt history", vim.log.levels.INFO)
		return
	end
	local win = vim.fn.bufwinid(chat.buf)
	require("aero.picker").close()
	require("aero.picker").open({
		title = "prompts for " .. chat.s.name,
		items = function() return M.items(chat) end,
		label = function(item) return "  " .. item.text:gsub("%s+", " ") end,
		preview = function(item) return item.text end,
		select = function(item)
			if chat.s.chat ~= chat or not api.nvim_buf_is_valid(chat.buf) then
				vim.notify("Aero: conversation is no longer available", vim.log.levels.INFO)
				return
			end
			if win == -1 or not api.nvim_win_is_valid(win) then
				win = require("aero.session").prepare_win(api.nvim_get_current_win())
			end
			api.nvim_win_set_buf(win, chat.buf)
			api.nvim_set_current_win(win)
			chat:goto_block(item.block)
		end,
	})
end

return M
