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
	-- Some adapters use human-readable titles rather than the tool's name.
	for _, value in ipairs({ block.rawOutput or false, block.rawInput or false }) do
		if type(value) == "string" then
			local ok, decoded = pcall(vim.json.decode, value)
			value = ok and decoded or false
		end
		if type(value) == "table" and value.todos ~= nil then
			local entries = parse(block.rawOutput) or parse(value.todos)
			if entries then return entries end
		end
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
	local bar = "%#AeroChatTool# " .. progress
	if active ~= "" then
		bar = bar .. "%#AeroChatPending# · " .. active:gsub("%%", "%%%%")
	end
	return bar
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
