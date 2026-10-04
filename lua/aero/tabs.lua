-- One tabpage per worktree: the tab's working directory (:tcd) is the worktree, so its windows,
-- file pickers and LSP all act on that checkout. The worktree is stored in t:aero_worktree.
local config = require("aero.config")
local events = require("aero.events")
local buffers = require("aero.buffers")

local M = {}

local api = vim.api

function M.enabled()
	return config.options.worktree_tabs ~= false
end

local function norm(path)
	return vim.fs.normalize(vim.fn.resolve(path))
end

local function inside(dir, root)
	dir, root = norm(dir), norm(root)
	return dir == root or dir:sub(1, #root + 1) == root .. "/"
end

local function dashboard_only(tab)
	local dashboard = false
	for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
		local buf = api.nvim_win_get_buf(win)
		if api.nvim_buf_get_name(buf) == "Aero://dashboard" then
			dashboard = true
		elseif
			api.nvim_buf_get_name(buf) ~= ""
			or vim.bo[buf].buftype ~= ""
			or vim.bo[buf].modified
			or api.nvim_buf_line_count(buf) ~= 1
			or api.nvim_buf_get_lines(buf, 0, 1, false)[1] ~= ""
		then
			return false
		end
	end
	return dashboard
end

--- The tab that belongs to `worktree`: one already assigned to it, else an unassigned tab whose
--- working directory is inside it, or the current dashboard-only tab (which is then claimed).
function M.find(worktree)
	local candidate
	local current = api.nvim_get_current_tabpage()
	for _, tab in ipairs(api.nvim_list_tabpages()) do
		if not vim.t[tab].aero_fullscreen and not vim.t[tab].aero_board_path then
			local assigned = vim.t[tab].aero_worktree
			if assigned and norm(assigned) == norm(worktree) then
				return tab
			end
			if not assigned and not candidate then
				local nr = api.nvim_tabpage_get_number(tab)
				if inside(vim.fn.getcwd(-1, nr), worktree) then
					candidate = tab
				end
			end
		end
	end
	if
		not vim.t[current].aero_worktree
		and not vim.t[current].aero_fullscreen
		and not vim.t[current].aero_board_path
		and dashboard_only(current)
	then
		candidate = current
	end
	if candidate then
		vim.t[candidate].aero_worktree = worktree
	end
	return candidate
end

--- Switch to the worktree's tab, restoring its last code buffer when creating one.
---@return boolean created whether a new tab was opened
function M.enter(worktree)
	buffers.remember()
	local tab = M.find(worktree)
	if tab then
		if tab ~= api.nvim_get_current_tabpage() then
			api.nvim_set_current_tabpage(tab)
		end
		vim.cmd.tcd(vim.fn.fnameescape(worktree))
		if not buffers.remember() then
			buffers.restore(worktree)
		end
		events.emit("worktree_entered", { path = worktree, tab = tab, created = false })
		return false
	end
	vim.cmd("$tabnew")
	vim.t.aero_worktree = worktree
	vim.cmd.tcd(vim.fn.fnameescape(worktree))
	buffers.restore(worktree, api.nvim_get_current_win())
	events.emit("worktree_entered", { path = worktree, tab = api.nvim_get_current_tabpage(), created = true })
	return true
end

--- Close the worktree's tab (e.g. after the worktree was removed), unless it is the last one.
function M.close(worktree)
	for _, tab in ipairs(api.nvim_list_tabpages()) do
		local assigned = vim.t[tab].aero_worktree
		if assigned and norm(assigned) == norm(worktree) and #api.nvim_list_tabpages() > 1 then
			vim.cmd.tabclose(api.nvim_tabpage_get_number(tab))
			return
		end
	end
end

return M
