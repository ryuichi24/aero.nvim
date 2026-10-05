-- Oil-style projection of retained ticket files: absent rows are deleted on :w.
local api = vim.api
local tasks = require("aero.tasks")
local M = {}
local views = {}
local function winbar(ws)
	local title = require("aero.tasks.edit").title
	local name = title(ws.name or vim.fs.basename(ws.root))
	local path = title(vim.fn.fnamemodify(ws.root, ":~"))
	local label = ("Removed tickets · %s [%s]"):format(name, path):gsub("%%", "%%%%")
	return label .. " — delete rows + :w · <CR> restore · R reload · q close"
end

local function show(view, ws)
	local origin = api.nvim_get_current_tabpage()
	if view.tab and api.nvim_tabpage_is_valid(view.tab) then
		if origin ~= view.tab then
			view.origin_tab = origin
		end
		api.nvim_set_current_tabpage(view.tab)
	else
		view.origin_tab = origin
		vim.cmd.tabnew()
		view.tab = api.nvim_get_current_tabpage()
		vim.t.aero_removed_workspace = ws.root
	end
	api.nvim_win_set_buf(0, view.buf)
	vim.wo.number = false
	vim.wo.relativenumber = false
	vim.wo.wrap = false
	vim.wo.winfixwidth = false
	vim.wo.winfixheight = false
	vim.wo.winbar = winbar(ws)
end

function M.open(ws, restore)
	local key = require("aero.storage").canonical(ws.root)
	local existing = views[key]
	if existing and api.nvim_buf_is_valid(existing.buf) then
		existing.restore = restore
		if not vim.bo[existing.buf].modified then
			existing.refresh()
		end
		show(existing, ws)
		return existing.buf
	end
	local buf = api.nvim_create_buf(false, true)
	local view = { buf = buf, restore = restore }
	views[key] = view
	local registry = {}
	local function notify(err)
		vim.notify("Aero tasks: " .. tostring(err), vim.log.levels.WARN)
	end
	local function refresh()
		local items = tasks.list_removed(ws)
		local lines = {}
		registry = {}
		for index, item in ipairs(items) do
			local id = tostring(index)
			item.text = require("aero.tasks.storage").read(item.path)
			item.row = id
				.. "  "
				.. require("aero.tasks.edit").title(item.title)
				.. " · from "
				.. require("aero.tasks.edit").title(item.board_title)
				.. " · "
				.. require("aero.tasks.edit").title(
					item.ticket and item.ticket.metadata and item.ticket.metadata.id or vim.fs.basename(item.path)
				)
				.. (item.error and " [invalid]" or "")
			registry[id] = item
			table.insert(lines, item.row)
		end
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modified = false
		-- A refresh starts a new baseline; old undo entries must not resurrect IDs.
		local levels = vim.bo[buf].undolevels
		vim.bo[buf].undolevels = -1
		api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].undolevels = levels
		vim.bo[buf].modified = false
	end
	view.refresh = refresh
	api.nvim_create_autocmd("BufWipeout", {
		buffer = buf,
		callback = function()
			if views[key] == view then
				views[key] = nil
			end
		end,
	})
	local function changed(items)
		for _, item in ipairs(items) do
			for id, original in pairs(registry) do
				if original.path == item.path then
					registry[id] = nil
				end
			end
			api.nvim_exec_autocmds("User", {
				pattern = "AeroTaskChanged",
				data = {
					workspace = ws,
					board_path = item.board_path,
					ticket_path = item.path,
				},
			})
		end
	end
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "aero-removed"
	api.nvim_buf_set_name(buf, "Aero://" .. ws.root .. "/removed-tickets/" .. buf)
	vim.b[buf].aero_workspace_root = ws.root
	api.nvim_create_autocmd("BufWriteCmd", {
		buffer = buf,
		callback = function()
			if vim.fn.getcmdwintype() ~= "" then
				return notify("close the command window before deleting tickets")
			end
			local retained = {}
			for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
				if vim.trim(line) ~= "" then
					local id = line:match("^(%d+)  ")
					if not id or not registry[id] or line ~= registry[id].row or retained[id] then
						return notify(
							"only row deletion and reordering are supported; undo other edits or reload with R"
						)
					end
					retained[id] = true
				end
			end
			local deleted = {}
			for id, item in pairs(registry) do
				if not retained[id] then
					table.insert(deleted, item)
				end
			end
			local result, err, partial = tasks.delete_removed(ws, deleted)
			changed(result or partial or {})
			if not result then
				return notify(err)
			end
			refresh()
		end,
	})
	vim.keymap.set("n", "<CR>", function()
		if vim.bo[buf].modified then
			return notify("save deletions with :w or reload with R before restoring")
		end
		local id = api.nvim_get_current_line():match("^(%d+)  ")
		if registry[id] then
			view.restore(registry[id], function()
				if api.nvim_buf_is_valid(buf) and not vim.bo[buf].modified then
					refresh()
				end
			end)
		end
	end, { buffer = buf, desc = "Aero: restore removed ticket" })
	vim.keymap.set("n", "R", refresh, { buffer = buf, desc = "Aero: reload removed tickets" })
	vim.keymap.set("n", "q", function()
		if view.tab and api.nvim_tabpage_is_valid(view.tab) then
			api.nvim_set_current_tabpage(view.tab)
			vim.cmd.tabclose()
		end
		if view.origin_tab and api.nvim_tabpage_is_valid(view.origin_tab) then
			api.nvim_set_current_tabpage(view.origin_tab)
		end
	end, { buffer = buf, desc = "Aero: close removed tickets" })
	refresh()
	show(view, ws)
	return buf
end

return M
