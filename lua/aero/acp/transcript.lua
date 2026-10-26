-- Transcript presentation: deferred minimal edits, cursor following and buffer mappings.
local api = vim.api
local renderer = require("aero.acp.render")
local options = require("aero.acp.editor_options")
local folds = require("aero.acp.folds")
local M = {}
local option_ns = api.nvim_create_namespace("Aero.acp.options")
local select_ns = api.nvim_create_namespace("Aero.acp.option_select")
local spinner_ns = api.nvim_create_namespace("Aero.acp.spinners")
local option_hl = {
	allow_once = "DiagnosticOk",
	allow_always = "DiagnosticOk",
	reject_once = "DiagnosticError",
	reject_always = "DiagnosticError",
}

function M.build_lines(chat)
	local lines, marks, options, blocks, sections = renderer.build(chat)
	chat.render_marks, chat.option_lines, chat.block_lines = marks, options, blocks
	chat.sections = sections
	return lines
end

function M.advance(chat, instant)
	local left = {}
	for _, block in ipairs(chat.revealing) do
		local text = block.text
		local revealed = instant and #text
			or math.min(#text, block.shown + math.max(3, math.ceil((#text - block.shown) / 8)))
		-- Reveal whole UTF-8 characters while catching up proportionally to backlog.
		while revealed < #text and text:byte(revealed + 1) >= 0x80 and text:byte(revealed + 1) < 0xC0 do
			revealed = revealed + 1
		end
		if revealed >= #text then
			block.shown = nil
		else
			block.shown = revealed
			table.insert(left, block)
		end
	end
	chat.revealing = left
	return #left > 0
end

function M.decorate_options(chat)
	api.nvim_buf_clear_namespace(chat.buf, option_ns, 0, -1)
	for line, option in pairs(chat.option_lines or {}) do
		api.nvim_buf_set_extmark(
			chat.buf,
			option_ns,
			line - 1,
			2,
			{ end_col = #chat.lines[line], hl_group = option_hl[option.kind] or "Normal" }
		)
	end
	chat:mark_selected()
end

function M.mark_selected(chat)
	local buf = chat.buf
	api.nvim_buf_clear_namespace(buf, select_ns, 0, -1)
	local win = vim.fn.bufwinid(buf)
	if win == -1 then
		return
	end
	if api.nvim_get_current_buf() == buf then
		win = api.nvim_get_current_win()
	end
	local line = api.nvim_win_get_cursor(win)[1]
	if (chat.option_lines or {})[line] then
		api.nvim_buf_set_extmark(
			buf,
			select_ns,
			line - 1,
			0,
			{ virt_text = { { "▸", "Special" } }, virt_text_pos = "overlay", line_hl_group = "CursorLine" }
		)
	end
end

function M.option_range(chat, block)
	local first, last
	for line, option in pairs(chat.option_lines or {}) do
		if option.block == (block or chat.permission and chat.permission.block) then
			first = (not first or line < first) and line or first
			last = (not last or line > last) and line or last
		end
	end
	return first, last
end

function M.goto_permission(chat, focus, block)
	local first, last = chat:option_range(block)
	if not first then
		return false
	end
	local tab, count = api.nvim_get_current_tabpage(), api.nvim_buf_line_count(chat.buf)
	for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
		api.nvim_win_call(win, function()
			api.nvim_win_set_cursor(win, { math.min(last + 2, count), 0 })
			vim.cmd("normal! zb")
			api.nvim_win_set_cursor(win, { first, 0 })
			vim.cmd("silent! normal! zv")
		end)
		if focus and api.nvim_win_get_tabpage(win) == tab then
			api.nvim_set_current_win(win)
			vim.cmd.stopinsert()
			focus = false
		end
	end
	chat:mark_selected()
	return true
end

function M.goto_block(chat, block, permission)
	chat:advance(true)
	chat:render()
	vim.defer_fn(function()
		if not api.nvim_buf_is_valid(chat.buf) then
			return
		end
		if permission then
			if chat.permission and not block.answer then
				chat:goto_permission(true, block)
			end
			return
		end
		local row = chat.block_lines and chat.block_lines[block]
		for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
			if api.nvim_win_get_tabpage(win) == api.nvim_get_current_tabpage() then
				api.nvim_win_set_cursor(win, { math.min(row or 1, api.nvim_buf_line_count(chat.buf)), 0 })
				api.nvim_win_call(win, function()
					vim.cmd("silent! normal! zv")
					vim.cmd("normal! zz")
				end)
			end
		end
	end, 32)
end

local function decorate(chat, first)
	local enabled = require("aero.config").options.acp.decorations ~= false
	if chat.decorations_enabled ~= enabled then
		first = 1
	elseif not first then
		return
	end
	chat.decorations_enabled = enabled
	renderer.decorate(chat.buf, chat.lines, chat.render_marks, first)
end

-- Spinner frames are display-only. Editing transcript text at animation speed
-- makes every buffer listener reprocess an increasingly large conversation.
function M.spin(chat)
	if chat.render_pending or not api.nvim_buf_is_valid(chat.buf) then
		return
	end
	local frame = require("aero.spinner").frame()
	for _, mark in ipairs(chat.spinner_marks or {}) do
		local text = frame
		if mark.activity then
			local icon = chat.permission and require("aero.config").options.icons.waiting or frame
			text = icon .. " " .. chat:activity() .. " (<C-c> to cancel)"
		end
		mark.id = api.nvim_buf_set_extmark(chat.buf, spinner_ns, mark.line - 1, mark.spinner_col, {
			id = mark.id,
			virt_text = { { text, mark.group or "AeroChatPending" } },
			virt_text_pos = "overlay",
			priority = 200,
			hl_mode = "combine",
		})
	end
end

local function spinners(chat)
	api.nvim_buf_clear_namespace(chat.buf, spinner_ns, 0, -1)
	chat.spinner_marks = {}
	for _, mark in ipairs(chat.render_marks or {}) do
		if mark.spinner_col ~= nil then
			table.insert(chat.spinner_marks, {
				line = mark.line,
				spinner_col = mark.spinner_col,
				group = mark.group,
				activity = mark.activity,
			})
		end
	end
	M.spin(chat)
end

function M.render(chat)
	if chat.render_pending then
		return
	end
	chat.render_pending = true
	vim.defer_fn(function()
		chat.render_pending = false
		local buf = chat.buf
		if not api.nvim_buf_is_valid(buf) then
			return
		end
		if chat:advance(vim.fn.bufwinid(buf) == -1) then
			chat:render()
		end
		local follow, last = {}, api.nvim_buf_line_count(buf)
		for _, win in ipairs(vim.fn.win_findbuf(buf)) do
			if api.nvim_win_get_cursor(win)[1] >= last then
				table.insert(follow, win)
			end
		end
		local old, new = chat.lines, chat:build_lines()
		require("aero.acp.todos").update(chat)
		if not old or #old ~= api.nvim_buf_line_count(buf) then
			old = api.nvim_buf_get_lines(buf, 0, -1, false)
		end
		local first = 1
		while first <= #old and first <= #new and old[first] == new[first] do
			first = first + 1
		end
		if first > #old and first > #new then
			chat.lines = new
			decorate(chat)
			spinners(chat)
			chat:decorate_options()
			folds.prepare(chat)
			folds.apply(chat)
			return
		end
		local old_last, new_last = #old, #new
		while old_last >= first and new_last >= first and old[old_last] == new[new_last] do
			old_last, new_last = old_last - 1, new_last - 1
		end
		folds.prepare(chat, { first = first, old_last = old_last, new_last = new_last })
		require("aero.acp.images").before_edit(buf, first)
		vim.bo[buf].modifiable = true
		local ok, err =
			pcall(api.nvim_buf_set_lines, buf, first - 1, old_last, false, vim.list_slice(new, first, new_last))
		vim.bo[buf].modifiable, vim.bo[buf].modified = false, false
		if not ok then
			folds.apply(chat, true)
			chat.lines = nil
			vim.notify("Aero: failed to render transcript: " .. tostring(err), vim.log.levels.ERROR)
			return
		end
		chat.lines = new
		decorate(chat, first)
		spinners(chat)
		folds.apply(chat)
		for _, win in ipairs(follow) do
			if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == buf then
				api.nvim_win_call(win, function()
					api.nvim_win_set_cursor(win, { math.max(1, api.nvim_buf_line_count(buf)), 0 })
					-- Edits above the tail can shift the focused window's viewport.
					-- Keep following bottom-aligned rather than relying on cursor scrolling.
					vim.cmd("normal! zb")
				end)
			end
		end
		chat:decorate_options()
		if chat.pending_focus then
			chat.pending_focus = false
			chat:goto_permission(false)
		end
	end, 16)
end

function M.setup(chat)
	local buf = chat.buf
	renderer.setup_highlights()
	require("aero.fullscreen").bind(buf)
	vim.bo[buf].buftype, vim.bo[buf].bufhidden, vim.bo[buf].swapfile = "nofile", "hide", false
	vim.bo[buf].modifiable = false
	options.filetype(buf, "markdown")
	vim.b[buf].aero_session = chat.s.key
	pcall(api.nvim_buf_set_name, buf, ("Aero://%s#%s"):format(chat.s.worktree, chat.s.name))
	local function map(lhs, callback, description)
		vim.keymap.set("n", lhs, callback, { buffer = buf, nowait = true, desc = "Aero: " .. description })
	end
	for _, lhs in ipairs({ "i", "a", "o", "I", "A" }) do
		map(lhs, function()
			chat:compose()
		end, "write prompt")
	end
	map("<CR>", function()
		chat:enter_key()
	end, "choose permission option / write prompt")
	map("p", function()
		chat:answer_permission()
	end, "go to the pending permission request")
	map("gY", function()
		chat:toggle_auto_yes()
	end, "toggle auto yes for this conversation")
	map("<C-g>", function()
		chat:toggle_prompt()
	end, "toggle prompt (draft is kept)")
	map("gP", function()
		require("aero.prompts").open(chat)
	end, "view session prompt history")
	map("]]", function()
		folds.jump(chat, 1)
	end, "next prompt turn")
	map("[[", function()
		folds.jump(chat, -1)
	end, "previous prompt turn")
	map("<C-c>", function()
		chat:cancel()
	end, "cancel turn")
	api.nvim_create_autocmd("CursorMoved", {
		buffer = buf,
		callback = function()
			if chat.permission then
				chat:mark_selected()
			end
		end,
	})
	api.nvim_create_autocmd("BufWinEnter", {
		buffer = buf,
		callback = function()
			options.apply(
				api.nvim_get_current_win(),
				vim.tbl_extend("force", options.transcript, options.line_numbers("transcript"))
			)
			folds.apply(chat)
		end,
	})
	for _, win in ipairs(vim.fn.win_findbuf(buf)) do
		options.apply(win, vim.tbl_extend("force", options.transcript, options.line_numbers("transcript")))
	end
	require("aero.acp.todos").attach(chat)
end

return M
