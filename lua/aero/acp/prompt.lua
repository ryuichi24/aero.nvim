-- Prompt-buffer presentation and draft submission. A lookup callback keeps retained
-- buffer mappings pointed at the current conversation after a session restart.
local api = vim.api
local M = {}

function M.send(chat)
	local buf = chat.prompt_buf
	if not (buf and api.nvim_buf_is_valid(buf)) then
		return
	end
	local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
	if text == "" then
		vim.bo[buf].modified = false
		return
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
	local function with_chat(method)
		return function()
			local current = lookup(key)
			if current then
				current[method](current)
			end
		end
	end
	api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = with_chat("send_prompt_buf") })
	local function map(mode, lhs, callback, description)
		vim.keymap.set(mode, lhs, callback, { buffer = buf, nowait = true, desc = "Aero: " .. description })
	end
	map({ "n", "i" }, "<C-s>", with_chat("send_prompt_buf"), "send prompt")
	local resize_keys = require("aero.layout").keys(true)
	local send_key = api.nvim_replace_termcodes("<C-s>", true, false, true)
	for _, name in ipairs({ "grow", "shrink", "narrow", "widen" }) do
		local binding = resize_keys and resize_keys[name]
		if binding and vim.startswith(api.nvim_replace_termcodes(binding, true, false, true), send_key) then
			vim.keymap.set(
				"n",
				"<C-s>",
				with_chat("send_prompt_buf"),
				{ buffer = buf, nowait = false, desc = "Aero: send prompt" }
			)
			break
		end
	end
	map("n", "<CR>", with_chat("send_prompt_buf"), "send prompt")
	vim.keymap.set("i", "<CR>", function()
		if require("aero.acp.path_menu").accept(buf) then
			return
		end
		if vim.fn.pumvisible() == 1 then
			local keys = vim.fn.complete_info({ "selected" }).selected == -1 and "<C-n><C-y>" or "<C-y>"
			api.nvim_feedkeys(api.nvim_replace_termcodes(keys, true, false, true), "in", false)
			return
		end
		local text = vim.trim(table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n"))
		if text == "/report" or text == "/cancel" or text == "/export" then
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
		api.nvim_win_set_buf(0, buf)
		if vim.bo[buf].filetype == "" then
			vim.bo[buf].filetype = "markdown"
		end
		require("aero.acp.editor_options").apply(0, {
			winfixheight = true,
			number = require("aero.config").options.acp.line_numbers.prompt,
		})
		layout.track(api.nvim_get_current_win(), "prompt", chat.s.key)
	end
	vim.cmd.startinsert({ bang = api.nvim_buf_get_lines(buf, 0, -1, false)[1] ~= "" })
end

return M
