-- Workspace and worktree navigation through the shared popup.
local M = {}
local store = require("aero.store")
local picker = require("aero.picker")

local function path(pathname)
	return vim.fn.fnamemodify(pathname, ":~")
end

function M.open()
	store.load()
	picker.open({
		title = "workspaces",
		items = function()
			local items = {}
			for _, ws in ipairs(store.data.workspaces) do
				table.insert(items, { key = ws.root, name = ws.name, root = ws.root })
			end
			return items
		end,
		label = function(ws)
			return ws.name .. "  " .. path(ws.root)
		end,
		sort = function(a, b)
			if a.name ~= b.name then
				return a.name < b.name
			end
			return a.root < b.root
		end,
		select = function(ws)
			require("aero").open_worktree(ws.root)
		end,
	})
end

function M.worktrees()
	store.load()
	local items, errors = {}, {}
	for _, ws in ipairs(store.data.workspaces) do
		local worktrees, err = require("aero.git").list(ws.root)
		if not worktrees then
			table.insert(errors, ws.name .. ": " .. err)
		end
		for _, wt in ipairs(worktrees or {}) do
			table.insert(items, { key = ws.root .. "::" .. wt.path, ws = ws, wt = wt })
		end
	end
	if #errors > 0 then
		vim.notify("Aero: cannot list worktrees\n" .. table.concat(errors, "\n"), vim.log.levels.WARN)
	end
	local function heading(item)
		return item.ws.name .. "  " .. path(item.ws.root)
	end
	local function label(item)
		local wt = item.wt
		return "  " .. (wt.branch or (wt.detached and "detached" or "checkout")) .. "  " .. path(wt.path)
	end
	picker.open({
		title = "worktrees",
		items = function()
			return items
		end,
		label = label,
		group = heading,
		search = function(item)
			return heading(item) .. " " .. label(item)
		end,
		sort = function(a, b)
			if a.ws.name ~= b.ws.name then
				return a.ws.name < b.ws.name
			end
			if a.ws.root ~= b.ws.root then
				return a.ws.root < b.ws.root
			end
			return a.wt.path < b.wt.path
		end,
		select = function(item)
			require("aero").open_worktree(item.wt.path)
		end,
	})
end

return M
