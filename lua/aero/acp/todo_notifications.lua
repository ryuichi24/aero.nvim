-- Notifications for live todo changes, independent of transcript focus.
local M = {}
local api = vim.api
local cards = {}
local recent = {}
local ns = api.nvim_create_namespace("Aero.todo_notifications")

local function layout()
	local width = math.max(1, math.min(64, vim.o.columns - 4))
	local available = math.max(1, vim.o.lines - vim.o.cmdheight - 4)
	local count = #cards
	local row = 1
	for _, card in ipairs(cards) do
		if card.win and api.nvim_win_is_valid(card.win)
			and api.nvim_win_get_tabpage(card.win) ~= api.nvim_get_current_tabpage() then
			api.nvim_win_close(card.win, true)
			card.win = nil
		end
		local height = math.max(1, math.min(#card.lines, math.floor(available / math.max(1, count)) - 2))
		local config = {
			relative = "editor", row = row, col = math.max(0, vim.o.columns - width - 2),
			width = width, height = height, border = "rounded", style = "minimal",
			title = " " .. card.name .. " · todos ", title_pos = "left", zindex = 60,
		}
		-- Keep the newest cards visible when the screen cannot fit every session.
		if row + height + 2 <= available + 2 then
			if card.win and api.nvim_win_is_valid(card.win) then
				api.nvim_win_set_config(card.win, config)
			else
				card.win = api.nvim_open_win(card.buf, false, config)
				vim.wo[card.win].wrap = false
			end
			row = row + height + 2
		elseif card.win and api.nvim_win_is_valid(card.win) then
			api.nvim_win_close(card.win, true)
			card.win = nil
		end
	end
end

function M.close(chat, forget)
	if forget then
		for index = #recent, 1, -1 do
			if recent[index] == chat then table.remove(recent, index) end
		end
	end
	for index, card in ipairs(cards) do
		if card.chat == chat then
			table.remove(cards, index)
			card.closed = true
			card.generation = (card.generation or 0) + 1
			if card.win and api.nvim_win_is_valid(card.win) then api.nvim_win_close(card.win, true) end
			if api.nvim_buf_is_valid(card.buf) then api.nvim_buf_delete(card.buf, { force = true }) end
			break
		end
	end
	layout()
end

local function arm_timeout(card)
	card.generation = (card.generation or 0) + 1
	local generation = card.generation
	local timeout = require("aero.config").options.acp.todo_notification_timeout
	if card.closed or type(timeout) ~= "number" or timeout <= 0 or card.focused then return end
	vim.defer_fn(function()
		if card.generation == generation then M.close(card.chat) end
	end, timeout)
end

function M.focus()
	if #cards == 0 then
		for _, chat in ipairs(recent) do
			if api.nvim_buf_is_valid(chat.buf) then
				M.update(chat, true)
				break
			end
		end
	end
	layout()
	for _, card in ipairs(cards) do
		if card.win and api.nvim_win_is_valid(card.win) then
			api.nvim_set_current_win(card.win)
			return true
		end
	end
	vim.notify("Aero: no todo notification popup is open", vim.log.levels.INFO)
	return false
end

function M.update(chat, force)
	local todos = require("aero.acp.todos").latest(chat)
	-- Historical replay seeds the baseline without generating notifications.
	local previous = chat.todo_notification_snapshot
	chat.todo_notification_snapshot = vim.deepcopy(todos)
	if chat.replaying or todos == nil or (not force and vim.deep_equal(previous, todos))
		or require("aero.config").options.acp.todo_notifications == false then return end
	for index = #recent, 1, -1 do
		if recent[index] == chat then table.remove(recent, index) end
	end
	table.insert(recent, 1, chat)
	local card
	for index, candidate in ipairs(cards) do
		if candidate.chat == chat then
			card = table.remove(cards, index)
			break
		end
	end
	if not card then
		card = { chat = chat, buf = api.nvim_create_buf(false, true) }
		vim.bo[card.buf].filetype = "aero_todos"
		for _, key in ipairs({ "q", "<Esc>" }) do
			vim.keymap.set("n", key, function() M.close(chat) end, { buffer = card.buf, nowait = true })
		end
		api.nvim_create_autocmd("BufEnter", { buffer = card.buf, callback = function()
			card.focused = true
			card.generation = (card.generation or 0) + 1
		end })
		api.nvim_create_autocmd("BufLeave", { buffer = card.buf, callback = function()
			card.focused = false
			arm_timeout(card)
		end })
		if not chat.todo_notification_cleanup then
			chat.todo_notification_cleanup = true
			api.nvim_create_autocmd("BufWipeout", { buffer = chat.buf, once = true, callback = function() M.close(chat, true) end })
		end
	end
	card.name = ((chat.s and chat.s.name) or "Agent"):gsub("%s+", " ")
	local completed = 0
	for _, todo in ipairs(todos) do if todo.status == "completed" then completed = completed + 1 end end
	card.lines = { ("Todos %d/%d completed · q to dismiss"):format(completed, #todos) }
	local rows = require("aero.acp.todos").rows(todos)
	for _, entry in ipairs(rows) do table.insert(card.lines, entry.text) end
	if #todos == 0 then table.insert(card.lines, "No current todos.") end
	vim.bo[card.buf].modifiable = true
	api.nvim_buf_set_lines(card.buf, 0, -1, false, card.lines)
	vim.bo[card.buf].modifiable = false
	api.nvim_buf_clear_namespace(card.buf, ns, 0, -1)
	for index, entry in ipairs(rows) do
		api.nvim_buf_set_extmark(card.buf, ns, index, 0, { end_col = #entry.text, hl_group = entry.group })
	end
	table.insert(cards, 1, card)
	layout()
	arm_timeout(card)
end

api.nvim_create_autocmd({ "VimResized", "TabEnter" }, {
	group = api.nvim_create_augroup("AeroTodoNotifications", { clear = true }), callback = layout,
})
return M
