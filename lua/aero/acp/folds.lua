-- Window-local transcript folds. Keys refer to source blocks, never persisted history.
local api = vim.api
local M = {}

local function state(view, section)
	view.closed[section.kind] = view.closed[section.kind] or {}
	return view.closed[section.kind]
end

function M.text()
	return vim.fn.getline(vim.v.foldstart):gsub("^#+%s*", "")
		.. ("  · %d lines"):format(vim.v.foldend - vim.v.foldstart)
end

function M.capture(chat)
	for win, view in pairs(chat.fold_views or {}) do
		if api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == chat.buf then
			api.nvim_win_call(win, function()
				local position, closed_folds = vim.fn.winsaveview(), {}
				for _, section in ipairs(view.sections) do
					local closed = vim.fn.foldclosed(section.first)
					state(view, section)[section.key] = closed == section.first
					if closed == section.first then
						-- Inspect nested folds too: the user may have opened a call and
						-- closed its parent since the last render. No redraw occurs here.
						table.insert(closed_folds, section.first)
						api.nvim_win_set_cursor(win, { section.first, 0 })
						vim.cmd("silent! normal! zo")
					end
				end
				for i = #closed_folds, 1, -1 do
					api.nvim_win_set_cursor(win, { closed_folds[i], 0 })
					vim.cmd("silent! normal! zc")
				end
				vim.fn.winrestview(position)
			end)
		else
			chat.fold_views[win] = nil
		end
	end
end

local function same(a, b)
	if #a ~= #b then
		return false
	end
	for i, section in ipairs(a) do
		local other = b[i]
		if
			section.key ~= other.key
			or section.kind ~= other.kind
			or section.first ~= other.first
			or section.last ~= other.last
			or section.critical ~= other.critical
		then
			return false
		end
	end
	return true
end

function M.apply(chat)
	chat.fold_views = chat.fold_views or {}
	for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
		local view = chat.fold_views[win]
		if not view then
			view = { sections = {}, closed = {}, previous = {} }
			chat.fold_views[win] = view
		end
		local sections = chat.sections or {}
		if not same(view.sections, sections) then
			api.nvim_win_call(win, function()
				local position = vim.fn.winsaveview()
				vim.wo.foldmethod, vim.wo.foldenable, vim.wo.foldlevel = "manual", true, 99
				vim.wo.foldtext = "v:lua.require'aero.acp.folds'.text()"
				vim.cmd("silent! normal! zE")
				-- Create children first; subsequent containing folds become their parents.
				for i = #sections, 1, -1 do
					local section = sections[i]
					if section.last > section.first then
						vim.cmd(("%d,%dfold"):format(section.first, section.last))
					end
				end
				vim.cmd("silent! normal! zR")
				for i = #sections, 1, -1 do
					local section = sections[i]
					local closed = state(view, section)
					if closed[section.key] == nil then
						closed[section.key] = section.closed == true
					end
					-- Expose a newly failed call or pending permission, but allow users to
					-- close it again after it has been shown once.
					local previous = (view.previous[section.kind] or {})[section.key]
					if section.critical and (not previous or previous.critical ~= section.critical) then
						closed[section.key] = false
					end
					if closed[section.key] and section.last > section.first then
						api.nvim_win_set_cursor(win, { section.first, 0 })
						vim.cmd("silent! normal! zc")
					end
				end
				view.sections = sections
				view.previous = {}
				for _, section in ipairs(sections) do
					view.previous[section.kind] = view.previous[section.kind] or {}
					view.previous[section.kind][section.key] = section
				end
				vim.fn.winrestview(position)
			end)
		end
	end
end

function M.jump(chat, direction)
	local row = api.nvim_win_get_cursor(0)[1]
	local turns = {}
	for _, section in ipairs(chat.sections or {}) do
		if section.kind == "turn" then
			table.insert(turns, section)
		end
	end
	if direction < 0 then
		turns = vim.fn.reverse(turns)
	end
	for _, section in ipairs(turns) do
		if direction * (section.first - row) > 0 then
			api.nvim_win_set_cursor(0, { section.first, 0 })
			return
		end
	end
end

return M
