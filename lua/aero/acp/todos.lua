-- Todos are derived from the current conversation, including restored history.
local M = {}
local api = vim.api
local states = {
	pending = { "○", "Pending", "AeroChatMeta", " " },
	in_progress = { "◉", "Working", "AeroChatPending", "~" },
	completed = { "✓", "Completed", "AeroChatSuccess", "x" },
	cancelled = { "−", "Cancelled", "AeroChatMeta", "-" },
}
local function single(text)
	return (text:gsub("%s+", " "))
end
local function parse(value)
	if type(value) == "string" then
		local ok, decoded = pcall(vim.json.decode, value)
		return ok and parse(decoded) or nil
	end
	if type(value) ~= "table" then
		return nil
	end
	if value.todos ~= nil then
		return parse(value.todos)
	end
	if not vim.islist(value) then
		return nil
	end
	for _, item in ipairs(value) do
		if type(item) ~= "table" or type(item.content) ~= "string" or not states[item.status] then
			return nil
		end
	end
	return value
end
function M.block(block)
	if block.kind == "plan" then
		return parse(block.entries)
	end
	if block.kind ~= "tool" or block.status == "failed" then
		return nil
	end
	local title = (block.title or ""):lower()
	local name = title:match("^([%w_]+)") or ""
	-- Namespaced calls and titles with arguments are also used by ACP adapters.
	for token in title:gmatch("[%w_]+") do
		if token == "todowrite" or token == "todoread" then
			name = token
			break
		end
	end
	if name ~= "todowrite" and name ~= "todoread" then
		return nil
	end
	local todos = parse(block.rawOutput) or parse(block.rawInput)
	if todos then
		return todos
	end
	for _, item in ipairs(block.content or {}) do
		todos = parse(item.content and item.content.text or item.text)
		if todos then
			return todos
		end
	end
end
function M.latest(chat)
	for index = #chat.blocks, 1, -1 do
		local todos = M.block(chat.blocks[index])
		if todos then
			return todos
		end
	end
end
function M.rows(todos)
	local rows = {}
	for _, todo in ipairs(todos) do
		local state = states[todo.status]
		local priority = ({ high = true, medium = true, low = true })[todo.priority] and (" · " .. todo.priority) or ""
		table.insert(rows, {
			text = ("- [%s] %s · %s %s%s"):format(state[4], single(todo.content), state[1], state[2], priority),
			group = state[3],
		})
	end
	return rows
end
local function summary(todos)
	local completed, active = 0, {}
	for _, todo in ipairs(todos) do
		if todo.status == "completed" then
			completed = completed + 1
		end
		if todo.status == "in_progress" then
			table.insert(active, single(todo.content))
		end
	end
	return ("Todos %d/%d completed"):format(completed, #todos), table.concat(active, " · ")
end
function M.winbar(chat)
	local todos = chat and M.latest(chat)
	if not todos then
		return nil
	end
	local progress, active = summary(todos)
	local bar = "%#AeroChatTool# " .. progress .. " · gT: list"
	if active ~= "" then
		bar = bar .. "%#AeroChatPending# · " .. active:gsub("%%", "%%%%")
	end
	return bar
end
function M.close(chat)
	local popup = chat.todo_popup
	chat.todo_popup = nil
	if popup and api.nvim_win_is_valid(popup.win) then
		api.nvim_win_close(popup.win, true)
	end
end
function M.update(chat)
	local todos = M.latest(chat)
	local wins = vim.fn.win_findbuf(chat.buf)
	chat.todo_winbars = chat.todo_winbars or {}
	chat.todo_originals = chat.todo_originals or {}
	local visible = {}
	for _, win in ipairs(wins) do
		visible[win] = true
	end
	for win, original in pairs(chat.todo_winbars) do
		if not visible[win] or not todos then
			if api.nvim_win_is_valid(win) then
				vim.wo[win].winbar = original
			end
			chat.todo_winbars[win] = nil
		end
	end
	if todos then
		local bar = M.winbar(chat)
		for _, win in ipairs(wins) do
			-- The panel composes this summary with session/model/assignment metadata.
			if require("aero.panel").win(api.nvim_win_get_tabpage(win)) ~= win then
				if chat.todo_winbars[win] == nil then
					local original = vim.wo[win].winbar
					-- Neovim may restore the buffer's last window-local value on re-entry.
					if original:find("%#AeroChatTool# Todos ", 1, true) == 1 then
						original = chat.todo_originals[win] or ""
					end
					chat.todo_winbars[win], chat.todo_originals[win] = original, original
				end
				vim.wo[win].winbar = bar
			end
		end
	end
	local popup = chat.todo_popup
	if not popup then
		return
	end
	if
		not api.nvim_win_is_valid(popup.win)
		or not api.nvim_win_is_valid(popup.parent)
		or api.nvim_win_get_buf(popup.parent) ~= chat.buf
	then
		M.close(chat)
		return
	end
	local progress, active = summary(todos or {})
	local lines, highlights = { progress }, { "AeroChatTool" }
	if active ~= "" then
		table.insert(lines, "Working on: " .. active)
		table.insert(highlights, "AeroChatPending")
	end
	table.insert(lines, "")
	table.insert(highlights, "AeroChatMeta")
	for _, row in ipairs(M.rows(todos or {})) do
		table.insert(lines, row.text)
		table.insert(highlights, row.group)
	end
	if not todos or #todos == 0 then
		table.insert(lines, "No current todos.")
		table.insert(highlights, "AeroChatMeta")
	end
	vim.bo[popup.buf].modifiable = true
	api.nvim_buf_set_lines(popup.buf, 0, -1, false, lines)
	vim.bo[popup.buf].modifiable = false
	local ns = api.nvim_create_namespace("Aero.acp.todos")
	api.nvim_buf_clear_namespace(popup.buf, ns, 0, -1)
	for index, group in ipairs(highlights) do
		api.nvim_buf_set_extmark(popup.buf, ns, index - 1, 0, { end_col = #lines[index], hl_group = group })
	end
	api.nvim_win_set_config(popup.win, {
		relative = "editor",
		row = 1,
		col = 2,
		width = math.max(1, math.min(90, vim.o.columns - 6)),
		height = math.max(1, math.min(#lines, math.floor(vim.o.lines / 2))),
	})
end
function M.open(chat)
	if chat.todo_popup and api.nvim_win_is_valid(chat.todo_popup.win) then
		api.nvim_set_current_win(chat.todo_popup.win)
		return
	end
	local parent = api.nvim_get_current_win()
	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		row = 1,
		col = 2,
		width = math.max(1, math.min(90, vim.o.columns - 6)),
		height = 1,
		border = "rounded",
		title = " Agent todos · q to close ",
		style = "minimal",
	})
	vim.wo[win].wrap, vim.wo[win].linebreak = true, true
	chat.todo_popup = { win = win, buf = buf, parent = parent }
	for _, key in ipairs({ "q", "<Esc>", "gT" }) do
		vim.keymap.set("n", key, function()
			M.close(chat)
		end, { buffer = buf, nowait = true, desc = "Aero: close todos" })
	end
	M.update(chat)
end
function M.attach(chat)
	local group = api.nvim_create_augroup("AeroTodos" .. chat.buf, { clear = true })
	api.nvim_create_autocmd("BufWinEnter", {
		group = group,
		buffer = chat.buf,
		callback = function()
			M.update(chat)
		end,
	})
	api.nvim_create_autocmd("BufWinLeave", {
		group = group,
		buffer = chat.buf,
		callback = function()
			-- winbar is window/buffer-local: restore before Neovim switches buffers.
			local win = api.nvim_get_current_win()
			local original = (chat.todo_winbars or {})[win]
			if original ~= nil then
				vim.wo[win].winbar = original
				chat.todo_winbars[win] = nil
			end
			vim.schedule(function()
				M.update(chat)
			end)
		end,
	})
	api.nvim_create_autocmd("BufWipeout", {
		group = group,
		buffer = chat.buf,
		once = true,
		callback = function()
			M.close(chat)
			api.nvim_del_augroup_by_id(group)
		end,
	})
	api.nvim_create_autocmd("VimResized", {
		group = group,
		callback = function()
			M.update(chat)
		end,
	})
	M.update(chat)
end
return M
