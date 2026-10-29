-- Document workflows receive selected items and report view changes explicitly.
local api = vim.api
local navigation = require("aero.navigation")
local reports = require("aero.reports")
local M = {}

local function notify(message, level)
	vim.notify("Aero: " .. message, level or vim.log.levels.WARN)
end

function M.open(item, how)
	if not navigation.enter_worktree(item.wt.path, { browse = true }) then
		return
	end

	local kind = item.kind == "export" and "exports" or item.kind == "reference_item" and "references" or "reports"
	api.nvim_set_current_win(navigation.code_window(kind))

	if how and how ~= "default" then
		vim.cmd(({ vsplit = "vsplit", split = "split", tab = "tab split" })[how])
	end

	vim.cmd.edit(vim.fn.fnameescape(item.report.path))
	local win = api.nvim_get_current_win()
	require("aero.buffers").remember(win)
	return win
end

function M.reading(item, create, on_create)
	if not navigation.enter_worktree(item.wt.path, { browse = true }) then
		return
	end

	api.nvim_set_current_win(navigation.code_window())

	if create then
		on_create()
		require("aero.reading").command("new", item.wt.path)
	else
		require("aero.reading").open(item.wt.path, item.reading.id)
	end
end

function M.create_report(item, created)
	reports.create(item.wt.path, item.ws, created)
end

function M.move(item, changed)
	if not item or item.kind ~= "report" then
		return
	end

	require("aero.workspaces").worktrees({
		title = "move report to worktree",
		exclude = item.wt.path,
		select = function(destination)
			local report, err = reports.move(item.report, destination.wt.path, destination.ws)

			if not report then
				return notify(err)
			end

			changed(report, destination.wt, destination.ws)
		end,
	})
end

function M.rename(item, changed)
	if item.kind == "board" then
		vim.ui.input(
			{ prompt = "Rename board: ", default = item.board.metadata and item.board.metadata.title },
			function(name)
				if not name or vim.trim(name) == "" then
					return
				end

				local ok, err = require("aero.tasks").rename_board(item.ws, item.board.path, vim.trim(name))

				if not ok then
					notify(err)
				end

				changed()
			end
		)
	elseif item.kind == "reference_item" then
		local entry = item.reference
		local stem = entry.kind ~= "directory" and entry.name:match("^(.+)%.[^.]+$")
		require("aero.input").input({
			prompt = "Rename reference item: ",
			default = entry.name,
			select_length = stem and #stem or nil,
		}, function(name)
			if not name or vim.trim(name) == "" then
				return
			end

			local renamed, err = require("aero.reference").rename(entry, name)

			if not renamed then
				return notify(err)
			end

			changed(renamed)
			require("aero.events").emit("reference_changed", { worktree = item.wt.path })
		end)
	elseif item.kind == "report" then
		reports.rename(item.report, changed)
	end
end

--- Return whether this item is a document, including cancelled/failed deletes.
function M.delete(item, changed)
	if item.kind == "board" then
		if vim.fn.confirm("Permanently delete board and ALL its tickets?", "&Yes\n&No", 2) ~= 1 then
			return true
		end

		local ok, err = require("aero.tasks").delete_board(item.ws, item.board.path)

		if not ok then
			notify(err)
			return true
		end
	elseif item.kind == "reference_item" then
		local entry = item.reference
		local label = entry.kind == "directory" and "reference folder and all its contents" or "reference item"

		if vim.fn.confirm("Delete " .. label .. " " .. entry.name .. "?", "&Yes\n&No", 2) ~= 1 then
			return true
		end

		local ok, err

		if entry.kind == "directory" then
			ok = vim.fn.delete(entry.path, "rf") == 0
			err = "could not remove folder: " .. entry.path
		else
			ok, err = vim.uv.fs_unlink(entry.path)
		end

		if not ok then
			notify("could not delete reference item: " .. tostring(err), vim.log.levels.ERROR)
			return true
		end

		require("aero.events").emit("reference_changed", { worktree = item.wt.path })
	elseif item.kind == "report" or item.kind == "export" then
		local label = item.kind == "export" and "exported log" or "report"

		if vim.fn.confirm("Delete " .. label .. " " .. item.report.name .. "?", "&Yes\n&No", 2) ~= 1 then
			return true
		end

		local ok, err = vim.uv.fs_unlink(item.report.path)

		if not ok then
			notify("could not delete " .. label .. ": " .. err, vim.log.levels.ERROR)
			return true
		end
	else
		return false
	end

	changed()
	return true
end

return M
