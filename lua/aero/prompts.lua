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

function M.open(chat, opts)
	opts = opts or {}

	if not chat then
		local s = require("aero.session_target").resolve("viewed")
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
		items = function()
			return M.items(chat)
		end,
		label = function(item)
			return "  " .. item.text:gsub("%s+", " ")
		end,
		preview = function(item)
			return item.text
		end,
		select = function(item)
			if chat.s.chat ~= chat or not api.nvim_buf_is_valid(chat.buf) then
				vim.notify("Aero: conversation is no longer available", vim.log.levels.INFO)
				return
			end

			if opts.compose then
				local buf = chat:get_prompt_buf()
				local draft = table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
				local text = vim.trim(draft) == "" and item.text or draft .. "\n\n" .. item.text
				api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
				chat:compose()
				api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(buf), 0 })
				vim.cmd.startinsert({ bang = true })
				return
			end

			if win == -1 or not api.nvim_win_is_valid(win) then
				win = require("aero.session").prepare_win(api.nvim_get_current_win())
			end

			require("aero.layout").set_buf(win, chat.buf)
			api.nvim_set_current_win(win)
			chat:goto_block(item.block)
		end,
	})
end

return M
