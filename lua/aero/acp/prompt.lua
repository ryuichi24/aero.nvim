-- Prompt-buffer presentation and draft submission. A lookup callback keeps retained
-- buffer mappings pointed at the current conversation after a session restart.
local api = vim.api
local M = {}

local function reference_command(text)
	return text == "/reference" or text == "/context"
end

local function enter_command(text)
	return text == "/prompt"
		or text == "/report"
		or reference_command(text)
		or text == "/cancel"
		or text == "/export"
		or text == "/resume"
end

-- Draft-building commands act on the current line, preserving the rest of the draft.
function M.command(chat)
	local buf = chat.prompt_buf
	if api.nvim_get_current_buf() ~= buf then
		return false
	end
	local row = api.nvim_win_get_cursor(0)[1]
	local text = vim.trim(api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "")
	if text == "/reading" or text:match("^/reading%s") then
		local function insert(title)
			if not title or vim.trim(title) == "" or not api.nvim_buf_is_valid(buf) then
				return
			end
			-- Do not overwrite a draft edited while the title input was open.
			if vim.trim(api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or "") ~= text then
				return
			end
			local template = require("aero.config").options.reading.prompt
			local request = template:gsub("{title}", function()
				return vim.json.encode(vim.trim(title))
			end)
			api.nvim_buf_set_lines(buf, row - 1, row, false, vim.split(request, "\n", { plain = true }))
		end
		local title = vim.trim(text:sub(#"/reading" + 1))
		if title == "" then
			vim.ui.input({ prompt = "Reading list title: " }, insert)
		else
			insert(title)
		end
		return true
	end
	if text == "/send" then
		api.nvim_buf_set_lines(buf, row - 1, row, false, {})
		M.send(chat, true)
		return true
	end
	if text == "/history" then
		api.nvim_buf_set_lines(buf, row - 1, row, false, {})
		require("aero.prompts").open(chat, { compose = true })
		return true
	end
	if text ~= "/prompt" and text ~= "/report" and not reference_command(text) then
		return false
	end
	if api.nvim_buf_line_count(buf) == 1 then
		return false
	end
	if (text == "/report" or reference_command(text)) and chat.state == "exited" then
		return false
	end
	api.nvim_buf_set_lines(buf, row - 1, row, false, {})
	if text == "/prompt" then
		require("aero.prompt_snippets").open(chat)
	elseif reference_command(text) then
		require("aero.reference").pick(chat.s)
	else
		require("aero.reports").pick(chat.s)
	end
	return true
end

function M.send(chat, submitting)
	local buf = chat.prompt_buf
	if not (buf and api.nvim_buf_is_valid(buf)) then
		return
	end
	if not submitting and M.command(chat) then
		return
	end
	local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
	if not text:find("\n", 1, true) and (text == "/reading" or text:match("^/reading%s")) then
		return M.command(chat)
	end
	if text == "" then
		vim.bo[buf].modified = false
		return
	end
	if text == "/prompt" then
		return require("aero.prompt_snippets").open(chat)
	end
	if text == "/resume" then
		api.nvim_buf_set_lines(buf, 0, -1, false, {})
		vim.bo[buf].modified = false
		return chat:prompt(text)
	end
	if chat.state == "exited" and text ~= "/export" then
		return chat:prompt(text)
	end
	if not chat.s.task_binding and (text:match("^/new%-ticket%s") or text == "/new-ticket") then
		return require("aero.tasks.agent").prepare_new_ticket(chat, function()
			chat:send_prompt_buf()
		end)
	end
	local expanded, err = require("aero.tasks.agent").expand_new_ticket(chat.s, text)
	if not expanded then
		vim.notify("Aero: " .. err, vim.log.levels.WARN)
		return
	end
	api.nvim_buf_set_lines(buf, 0, -1, false, {})
	vim.bo[buf].modified = false
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		api.nvim_win_close(win, true)
	end
	vim.cmd.stopinsert()
	for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
		api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(chat.buf), 0 })
	end
	chat:prompt(expanded)
end

function M.buffer(chat, lookup)
	if chat.prompt_buf and api.nvim_buf_is_valid(chat.prompt_buf) then
		return chat.prompt_buf
	end
	local buf = api.nvim_create_buf(false, true)
	chat.prompt_buf = buf
	vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "acwrite", "hide", false
	pcall(api.nvim_buf_set_name, buf, ("Aero://%s#%s/prompt"):format(chat.s.worktree, chat.s.name))
	local key = chat.s.key
	if chat.draft and #chat.draft > 0 then
		api.nvim_buf_set_lines(buf, 0, -1, false, chat.draft)
	end
	vim.bo[buf].modified = false
	api.nvim_buf_attach(buf, false, {
		on_lines = function()
			local current = lookup(key)
			if current then
				current.draft = api.nvim_buf_get_lines(buf, 0, -1, false)
				current:save_history()
			end
		end,
	})
	local function with_chat(method)
		return function()
			local current = lookup(key)
			if current then
				current[method](current)
			end
		end
	end
	api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			vim.notify("Aero: draft kept; press Ctrl-Enter to submit", vim.log.levels.INFO)
		end,
	})
	local function map(mode, lhs, callback, description)
		vim.keymap.set(mode, lhs, callback, { buffer = buf, nowait = true, desc = "Aero: " .. description })
	end
	map({ "n", "i" }, "<C-CR>", with_chat("send_prompt_buf"), "send prompt")
	map("n", "<CR>", function()
		local current = lookup(key)
		if current and M.command(current) then
			return
		end
		local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
		if enter_command(text) then
			with_chat("send_prompt_buf")()
			return
		end
		local row = api.nvim_win_get_cursor(0)[1]
		api.nvim_buf_set_lines(buf, row, row, false, { "" })
		api.nvim_win_set_cursor(0, { row + 1, 0 })
		vim.cmd.startinsert()
	end, "slash command / newline")
	vim.keymap.set("i", "<CR>", function()
		if require("aero.acp.path_menu").accept(buf) then
			return
		end
		if vim.fn.pumvisible() == 1 then
			local keys = vim.fn.complete_info({ "selected" }).selected == -1 and "<C-n><C-y>" or "<C-y>"
			api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "in", false)
			return
		end
		local current = lookup(key)
		if current and M.command(current) then
			return
		end
		local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
		if enter_command(text) then
			with_chat("send_prompt_buf")()
		else
			api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "in", false)
		end
	end, { buffer = buf, desc = "Aero: report picker / cancel / newline" })
	map("n", "q", "<cmd>close<cr>", "close prompt (draft is kept)")
	map({ "n", "i" }, "<C-g>", with_chat("toggle_prompt"), "toggle prompt (draft is kept)")
	map({ "n", "i" }, "<C-c>", with_chat("cancel"), "cancel turn")
	vim.bo[buf].omnifunc = "v:lua.require'aero.acp'.omnifunc"
	vim.b[buf].aero_chat_key = key
	require("aero.acp.completion").setup(buf, chat.s.worktree)
	require("aero.fullscreen").bind(buf)
	return buf
end

function M.toggle(chat)
	local tab, closed = api.nvim_get_current_tabpage(), false
	if chat.prompt_buf and api.nvim_buf_is_valid(chat.prompt_buf) then
		for _, win in ipairs(vim.fn.win_findbuf(chat.prompt_buf)) do
			if api.nvim_win_get_tabpage(win) == tab then
				vim.cmd.stopinsert()
				api.nvim_win_close(win, true)
				closed = true
			end
		end
	end
	if not closed then
		return chat:compose()
	end
	local transcript = vim.fn.bufwinid(chat.buf)
	if transcript ~= -1 then
		api.nvim_set_current_win(transcript)
	end
end

function M.compose(chat)
	local buf, tab = chat:get_prompt_buf(), api.nvim_get_current_tabpage()
	local existing = vim.tbl_filter(function(win)
		return api.nvim_win_get_tabpage(win) == tab
	end, vim.fn.win_findbuf(buf))
	if #existing > 0 then
		api.nvim_set_current_win(existing[1])
	else
		local transcript = vim.fn.bufwinid(chat.buf)
		if transcript ~= -1 then
			api.nvim_set_current_win(transcript)
		end
		local layout = require("aero.layout")
		vim.cmd(("belowright %dsplit"):format(layout.prompt_height(chat.s.key)))
		require("aero.layout").set_buf(0, buf)
		if vim.bo[buf].filetype == "" then
			vim.bo[buf].filetype = "markdown"
		end
		local options = require("aero.acp.editor_options")
		options.apply(0, vim.tbl_extend("force", { winfixheight = true }, options.line_numbers("prompt")))
		layout.track(api.nvim_get_current_win(), "prompt", chat.s.key)
	end
	vim.cmd.startinsert({ bang = api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= "" })
end

return M
