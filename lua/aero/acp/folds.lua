-- Let Neovim shift/extend manual folds with text edits. Only replace folds whose
-- boundaries are overwritten, and create folds for newly rendered sections.
local api = vim.api
local M = {}

local function initialize(buf, callback)
	local highlighter = vim.treesitter.highlighter.active[buf]

	if not highlighter then
		return callback()
	end

	-- Building native folds visits the whole history. Do not highlight each
	-- temporary cursor location (and parse every fenced language) on the way.
	local language = highlighter.tree:lang()
	vim.treesitter.stop(buf)
	local ok, err = xpcall(callback, debug.traceback)
	local resumed, resume_err = pcall(vim.treesitter.start, buf, language)

	if not ok then
		error(err, 0)
	end

	if not resumed then
		error(resume_err, 0)
	end
end

local function index(sections)
	local result = {}

	for _, section in ipairs(sections) do
		result[section.kind] = result[section.kind] or {}
		result[section.kind][section.key] = section
	end

	return result
end

local function lookup(indexed, section)
	return (indexed[section.kind] or {})[section.key]
end

function M.text()
	local text = vim.fn.getline(vim.v.foldstart):gsub("^#+%s*", "")
		.. ("  · %d lines"):format(vim.v.foldend - vim.v.foldstart)

	-- Cover the header's line highlight across the closed summary, not just its text.
	return { { text .. string.rep(" ", api.nvim_win_get_width(0)), "AeroChatFolded" } }
end

-- Fold boundaries strictly outside a replacement move automatically, including
-- enclosing folds. A replaced boundary or an insertion beyond a fold's tail
-- needs an explicit replacement instead.
local function retained(old, new, edit)
	if not new then
		return false
	end

	local first, last = old.first, old.last

	if edit then
		local delta = edit.new_last - edit.old_last

		if first > edit.old_last then
			first, last = first + delta, last + delta
		elseif last < edit.first then
			-- This fold is entirely before the edit.
		elseif first < edit.first and last > edit.old_last then
			last = last + delta
		else
			return false
		end
	end

	return first == new.first and last == new.last
end

local function plan(view, sections, edit)
	local old_index, new_index = index(view.sections), index(sections)
	local pending = { remove = {}, create = {}, restore = {}, alerts = {}, old_index = old_index }

	for _, old in ipairs(view.sections) do
		if not retained(old, lookup(new_index, old), edit) then
			table.insert(pending.remove, old)
		end
	end

	for _, section in ipairs(sections) do
		local old = lookup(old_index, section)

		if not old or not retained(old, section, edit) then
			table.insert(pending.create, section)
		end

		if section.critical and (not old or old.critical ~= section.critical) then
			table.insert(pending.alerts, section)
		end
	end

	return pending
end

local function expose(row)
	while vim.fn.foldclosed(row) ~= -1 do
		api.nvim_win_set_cursor(0, { vim.fn.foldclosed(row), 0 })
		vim.cmd("silent! normal! zo")
	end
end

-- Called before changing buffer text. Inspect only folds being replaced and the
-- closed ancestors hiding them, never walk/open all the historical folds.
function M.prepare(chat, edit)
	local editor = require("aero.acp.editor_state").get(chat)

	for win, view in pairs(editor.fold_views or {}) do
		if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= chat.buf then
			editor.fold_views[win] = nil
		else
			local pending = plan(view, editor.sections or {}, edit)
			view.pending = pending

			if #pending.remove > 0 then
				api.nvim_win_call(win, function()
					local position = vim.fn.winsaveview()
					local by_line = {}

					for _, old in ipairs(view.sections) do
						by_line[old.first] = old
					end

					for i = #pending.remove, 1, -1 do
						local section = pending.remove[i]
						local row = vim.fn.foldclosed(section.first)
						while row ~= -1 and row ~= section.first do
							local ancestor = by_line[row]

							if ancestor then
								pending.restore[ancestor] = true
							end

							api.nvim_win_set_cursor(0, { row, 0 })
							vim.cmd("silent! normal! zo")
							row = vim.fn.foldclosed(section.first)
						end

						if pending.restore[section] == nil then
							pending.restore[section] = row == section.first
						end

						api.nvim_win_set_cursor(0, { section.first, 0 })
						vim.cmd("silent! normal! zd")
					end

					vim.fn.winrestview(position)
				end)
			end
		end
	end
end

function M.apply(chat, abort)
	local editor = require("aero.acp.editor_state").get(chat)
	editor.fold_views = editor.fold_views or {}

	for _, win in ipairs(vim.fn.win_findbuf(chat.buf)) do
		local view = editor.fold_views[win]
		local fresh = not view

		if fresh then
			view = { sections = {} }
			editor.fold_views[win] = view
		end

		local sections = abort and view.sections or editor.sections or {}
		local pending = view.pending or plan(view, sections)

		if abort then
			pending.create, pending.alerts = pending.remove, {}
		end

		local new_index = index(sections)

		if fresh or #pending.create > 0 or next(pending.restore) or #pending.alerts > 0 then
			local function apply()
				api.nvim_win_call(win, function()
					local position = vim.fn.winsaveview()

					if fresh then
						api.nvim_set_hl(0, "AeroChatFolded", { link = "Folded", default = true })
						local highlights = vim.split(vim.wo.winhighlight, ",", { trimempty = true })

						for i = #highlights, 1, -1 do
							if highlights[i]:match("^Folded:") then
								table.remove(highlights, i)
							end
						end

						table.insert(highlights, "Folded:AeroChatFolded")
						vim.wo.winhighlight = table.concat(highlights, ",")
						vim.wo.foldmethod, vim.wo.foldenable, vim.wo.foldlevel = "manual", true, 99
						vim.wo.foldtext = "v:lua.require'aero.acp.folds'.text()"
						vim.cmd("silent! normal! zE")
					end

					for i = #pending.create, 1, -1 do
						local section = pending.create[i]

						if section.last > section.first then
							-- Creating a containing fold preserves the existing child folds.
							vim.cmd(("%d,%dfold"):format(section.first, section.last))
							api.nvim_win_set_cursor(0, { section.first, 0 })
							vim.cmd("silent! normal! zo")
						end
					end

					local closed = {}

					for old, value in pairs(pending.restore) do
						local section = lookup(new_index, old)

						if section then
							closed[section] = value
						end
					end

					for _, section in ipairs(pending.create) do
						if closed[section] == nil then
							closed[section] = section.closed == true
						end
					end

					-- Close children before parents, without resetting unrelated folds.
					for i = #sections, 1, -1 do
						local section = sections[i]

						if closed[section] and section.last > section.first then
							api.nvim_win_set_cursor(0, { section.first, 0 })
							vim.cmd("silent! normal! zc")
						end
					end

					for _, section in ipairs(pending.alerts) do
						expose(section.first)
					end

					vim.fn.winrestview(position)
				end)
			end

			if fresh then
				initialize(chat.buf, apply)
			else
				apply()
			end
		end

		view.sections, view.pending = sections, nil
	end
end

function M.jump(chat, direction)
	local row = api.nvim_win_get_cursor(0)[1]
	local turns = {}

	for _, section in ipairs(require("aero.acp.editor_state").get(chat).sections or {}) do
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
