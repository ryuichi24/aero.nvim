-- Quote a visual selection into an agent's draft without yanking or submitting it.
local api = vim.api
local config = require("aero.config")
local sessions = require("aero.session")
local panel = require("aero.panel")
local M = {}
local mapped_key

local function notify(message)
	vim.notify("Aero: " .. message, vim.log.levels.WARN)
end

local function source_session(buf)
	local s = sessions.from_buf(buf)
	if s then
		return s
	end
	local key = vim.b[buf].aero_chat_key
	if key then
		for _, candidate in ipairs(sessions.all()) do
			if candidate.key == key then
				return candidate
			end
		end
	end
end

local function selection(range)
	local buf = api.nvim_get_current_buf()
	local mode = vim.fn.mode()
	local first, last, lines
	if mode == "v" or mode == "V" or mode == "\022" then
		first, last = vim.fn.getpos("v"), vim.fn.getpos(".")
		lines = vim.fn.getregion(first, last, { type = mode, exclusive = vim.o.selection == "exclusive" })
	elseif range then
		first, last = { buf, range[1], 1, 0 }, { buf, range[2], 1, 0 }
		lines = api.nvim_buf_get_lines(buf, range[1] - 1, range[2], false)
	else
		notify("select text in Visual mode first")
		return
	end
	if #lines == 0 then
		return
	end
	return {
		lines = lines,
		first = math.min(first[2], last[2]),
		last = math.max(first[2], last[2]),
		name = api.nvim_buf_get_name(buf),
		filetype = vim.bo[buf].filetype,
		session = source_session(buf),
		win = api.nvim_get_current_win(),
		visual = mode == "v" or mode == "V" or mode == "\022",
	}
end

local function format_quote(source, target)
	local name, language
	if source.session then
		name, language = "agent log: " .. source.session.name, "text"
	else
		name = source.name ~= "" and source.name or "[No Name]"
		local root = vim.fs.normalize(vim.fn.resolve(target.worktree)) .. "/"
		local path = vim.fs.normalize(vim.fn.resolve(name))
		if vim.startswith(path, root) then
			name = path:sub(#root + 1)
		else
			name = vim.fn.fnamemodify(name, ":~")
		end
		language = source.filetype:gsub("[^%w_-]", "")
	end
	local length = 3
	for ticks in table.concat(source.lines, "\n"):gmatch("`+") do
		length = math.max(length, #ticks + 1)
	end
	local fence = string.rep("`", length)
	local lines = { ("Quoted from %s (lines %d-%d):"):format(name, source.first, source.last), "", fence .. language }
	vim.list_extend(lines, source.lines)
	table.insert(lines, fence)
	return lines
end

local function show(target, source)
	if panel.enabled() then
		return panel.show(target)
	end
	for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
		if api.nvim_win_get_buf(win) == target.buf then
			return sessions.show(target, win, false)
		end
	end
	local source_win = api.nvim_win_is_valid(source.win) and source.win or api.nvim_get_current_win()
	local win = api.nvim_open_win(api.nvim_create_buf(false, true), false, { split = "right", win = source_win })
	return sessions.show(target, win, false)
end

local function append(source, target)
	local win = show(target, source)
	if not win then
		return
	end
	local lines = format_quote(source, target)
	if target.chat then
		local buf = target.chat:get_prompt_buf()
		local draft = api.nvim_buf_get_lines(buf, 0, -1, false)
		if #draft == 1 and draft[1] == "" then
			draft = {}
		elseif draft[#draft] ~= "" then
			table.insert(draft, "")
		end
		vim.list_extend(draft, lines)
		table.insert(draft, "")
		api.nvim_buf_set_lines(buf, 0, -1, false, draft)
		target.chat:compose()
		api.nvim_win_set_cursor(0, { #draft, 0 })
		if not config.options.start_insert then
			vim.cmd.stopinsert()
		end
	else
		-- Terminal agents receive a bracketed paste, with no submit keystroke.
		if not target.job then
			notify("the terminal agent exited before the quote could be pasted")
			return
		end
		api.nvim_set_current_win(win)
		vim.fn.chansend(target.job, "\027[200~" .. table.concat(lines, "\n") .. "\n\027[201~")
		if config.options.start_insert then
			vim.cmd.startinsert()
		end
	end
end

function M.quote(range)
	local source = selection(range)
	if not source then
		return
	end
	if source.visual then
		vim.cmd("normal! " .. api.nvim_replace_termcodes("<Esc>", true, false, true))
	end
	local target = source.session or panel.current_session()
	if target then
		return append(source, target)
	end
	local candidates = sessions.list(vim.t.aero_worktree or vim.fn.getcwd())
	if #candidates == 0 then
		notify("start an agent session in this worktree before quoting text")
	elseif #candidates == 1 then
		append(source, candidates[1])
	else
		vim.ui.select(candidates, {
			prompt = "Quote to agent session",
			format_item = function(s)
				return s.name .. " (" .. s.agent .. ")"
			end,
		}, function(s)
			if s then
				append(source, s)
			end
		end)
	end
end

function M.setup()
	if mapped_key then
		local map = vim.fn.maparg(mapped_key, "x", false, true)
		if map.callback == M.quote and map.buffer == 0 then
			vim.keymap.del("x", mapped_key)
		end
	end
	mapped_key = config.options.quote_key
	if mapped_key then
		vim.keymap.set("x", mapped_key, M.quote, { desc = "Aero: quote selection into agent prompt" })
	end
end

return M
