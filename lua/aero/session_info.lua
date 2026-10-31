-- Live, independently scrollable metadata for the agent panel's selected session.
local api = vim.api
local M = {}
local tabs = {}
local namespace = api.nvim_create_namespace("AeroSessionInfo")
local sections = { Session = true, Usage = true, Task = true, Knowledge = true, ["Active sources"] = true }

local function highlights()
	for group, link in pairs({
		AeroInfoSection = "Title",
		AeroInfoLabel = "Comment",
		AeroInfoValue = "Normal",
		AeroInfoTag = "Type",
		AeroInfoSource = "Directory",
		AeroInfoMuted = "Comment",
		AeroInfoIdle = "DiagnosticOk",
		AeroInfoBusy = "DiagnosticInfo",
		AeroInfoWaiting = "DiagnosticWarn",
		AeroInfoStopped = "Comment",
	}) do
		api.nvim_set_hl(0, group, { link = link, default = true })
	end
end

local function decorate(buf, lines, session)
	api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
	local sources = false
	local function mark(row, first, last, group)
		api.nvim_buf_set_extmark(buf, namespace, row - 1, first, {
			end_col = last,
			hl_group = group,
		})
	end

	for row, line in ipairs(lines) do
		local heading = line:match("^  ── (.-) ──$")

		if heading then
			sources = heading == "Active sources"
			mark(row, 0, #line, "AeroInfoSection")
		elseif line ~= "" then
			local label = line:match("^%s*[^:]+: ")
			local group = sources and not label and "AeroInfoSource" or "AeroInfoValue"

			if label then
				mark(row, 0, #label, "AeroInfoLabel")

				if label:find("Tags:", 1, true) then
					group = "AeroInfoTag"
				elseif label:find("Status:", 1, true) and session then
					group = ({ idle = "AeroInfoIdle", busy = "AeroInfoBusy", waiting = "AeroInfoWaiting" })[require(
						"aero.session"
					).status(session)] or "AeroInfoStopped"
				end
			end

			local start = label and #label or 0
			mark(row, start, #line, group)
			local missing = line:find("not reported", start + 1, true)

			if missing then
				mark(row, missing - 1, #line, "AeroInfoMuted")
			end
		end
	end
end

function M.win(tab)
	local state = tabs[tab or api.nvim_get_current_tabpage()]
	return state and api.nvim_win_is_valid(state.win) and state.win or nil
end

function M.lines(session)
	local chat = session.chat or require("aero.history").load(session)
	local lines = {
		"Session",
		"Name: " .. session.name,
		"Agent: " .. session.agent,
		"Status: " .. (require("aero.session").activity(session) or require("aero.session").status(session)),
		"Model: " .. (session.chat and session.chat:model_title() or "not reported"),
		"Mode: " .. (session.chat and session.chat:mode_title() or "not reported"),
		"Location: " .. session.worktree,
		"",
		"Usage",
	}
	vim.list_extend(lines, require("aero.acp.usage").lines(chat))

	if not (chat and chat.usage and chat.usage.context) then
		table.insert(lines, "Context: not reported")
	end

	vim.list_extend(lines, { "", "Task", require("aero.tasks.status").label(session) })
	local todo_view = require("aero.acp.todos")
	local todos = chat and todo_view.latest(chat)

	if todos then
		for _, row in ipairs(todo_view.rows(todos)) do
			table.insert(lines, row.text)
		end
	end

	local has_knowledge, knowledge = pcall(require, "aero.knowledge.agent")
	local label = has_knowledge and knowledge.label(session)

	if label then
		vim.list_extend(lines, { "", "Knowledge" })
		vim.list_extend(lines, vim.split(label, " · ", { plain = true }))
		vim.list_extend(lines, { "", "Active sources" })
		local ok, sources =
			pcall(knowledge.sources, knowledge.scope(session), require("aero.knowledge.store").catalog())

		if ok then
			for _, item in ipairs(sources) do
				local source = item.source
				table.insert(lines, item.space .. " / " .. (source.relative_path or source.name))
				table.insert(
					lines,
					"  Tags: " .. (#(source.tags or {}) > 0 and table.concat(source.tags, ", ") or "none")
				)
			end
		end
	end

	for index, line in ipairs(lines) do
		if sections[line] then
			lines[index] = "  ── " .. line .. " ──"
		elseif line ~= "" then
			lines[index] = "  " .. line
		end
	end

	return lines
end

function M.update()
	for tab, state in pairs(tabs) do
		if not api.nvim_tabpage_is_valid(tab) or not api.nvim_win_is_valid(state.win) then
			tabs[tab] = nil
		else
			local panel = require("aero.panel").win(tab)
			local session = panel and require("aero.session").from_buf(api.nvim_win_get_buf(panel))
			local lines = session and M.lines(session) or { "No session selected" }

			if not vim.deep_equal(lines, state.lines) then
				local view = api.nvim_win_call(state.win, vim.fn.winsaveview)
				vim.bo[state.buf].modifiable = true
				api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
				decorate(state.buf, lines, session)
				vim.bo[state.buf].modifiable = false
				api.nvim_win_call(state.win, function()
					vim.fn.winrestview(view)
				end)
				state.lines = lines
			end
		end
	end
end

function M.close()
	local win = M.win()

	if win then
		api.nvim_win_close(win, true)
	end

	tabs[api.nvim_get_current_tabpage()] = nil
	require("aero.panel").refresh()
end

function M.reflow()
	local options = require("aero.config").options.panel

	if not options or options.info_auto_position == false then
		return
	end

	local tab = api.nvim_get_current_tabpage()
	local state = tabs[tab]
	local panel = require("aero.panel").win(tab)

	if not state or not M.win(tab) or not panel then
		return
	end

	local width = api.nvim_win_get_width(panel)

	if state.wide then
		width = width + api.nvim_win_get_width(state.win) + 1
	end

	local wide = width >= options.info_position_threshold_columns

	if wide == state.wide then
		return
	end

	local view = api.nvim_win_call(state.win, vim.fn.winsaveview)
	local height = api.nvim_win_get_height(panel)
	state.wide = wide
	api.nvim_win_set_config(state.win, {
		win = panel,
		split = wide and "right" or "above",
		width = wide and 36 or nil,
		height = not wide and math.max(3, math.min(12, math.floor(height / 3))) or nil,
	})
	api.nvim_win_call(state.win, function()
		vim.fn.winrestview(view)
	end)
end

function M.toggle()
	if M.win() then
		return M.close()
	end

	local panel = require("aero.panel").win()

	if not panel then
		return vim.notify("Aero: open an agent session in the panel first", vim.log.levels.INFO)
	end

	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "aero_info"
	require("aero.layout").bind(buf)
	local wide = api.nvim_win_get_width(panel) >= require("aero.config").options.panel.info_position_threshold_columns
	local win = api.nvim_open_win(buf, false, {
		split = wide and "right" or "above",
		win = panel,
		width = wide and 36 or nil,
		height = not wide and math.max(3, math.min(12, math.floor(api.nvim_win_get_height(panel) / 3))) or nil,
	})
	vim.wo[win].wrap = true
	vim.wo[win].linebreak = true
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldenable = false
	vim.wo[win].list = false
	vim.wo[win].spell = false
	vim.wo[win].winbar = " %#AeroInfoSection#Session info%* %=%#AeroInfoMuted#q close %*"
	tabs[api.nvim_get_current_tabpage()] = { win = win, buf = buf, wide = wide }
	vim.keymap.set("n", "q", M.close, { buffer = buf, silent = true })
	M.update()
	require("aero.panel").refresh()
end

api.nvim_create_autocmd("WinClosed", {
	group = api.nvim_create_augroup("AeroSessionInfo", { clear = true }),
	callback = function(event)
		for tab, state in pairs(tabs) do
			if state.win == tonumber(event.match) then
				tabs[tab] = nil
				vim.schedule(function()
					require("aero.panel").refresh()
				end)
			end
		end
	end,
})
highlights()
api.nvim_create_autocmd({ "WinResized", "VimResized", "TabEnter" }, {
	group = "AeroSessionInfo",
	callback = function()
		vim.schedule(M.reflow)
	end,
})
api.nvim_create_autocmd("ColorScheme", {
	group = "AeroSessionInfo",
	callback = highlights,
})
return M
