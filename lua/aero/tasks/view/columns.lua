-- Column metadata decorations and mappings; never reload or mutate task documents.
local api = vim.api
local config = require("aero.config")
local edit = require("aero.tasks.edit")
local M = {}
local ns = api.nvim_create_namespace("Aero.tasks")

local function detail(item, state)
	if item.error then
		return "! " .. edit.title(item.error)
	end
	local data, parts = item.ticket and item.ticket.metadata or {}, {}
	if data.priority then
		table.insert(parts, data.priority)
	end
	for _, name in ipairs(data.assignees or {}) do
		table.insert(parts, "@" .. name)
	end
	if data.due_date then
		local overdue = not vim.tbl_contains(config.options.tasks.terminal_states, state)
			and data.due_date < os.date("!%Y-%m-%d")
		table.insert(parts, (overdue and "OVERDUE " or "due ") .. data.due_date)
	end
	if data.estimate then
		table.insert(parts, data.estimate .. " " .. config.options.tasks.estimate_unit)
	end
	for _, tag in ipairs(data.tags or {}) do
		table.insert(parts, "#" .. tag)
	end
	return edit.title(table.concat(parts, " · "))
end

function M.decorate(view, only)
	for _, column in ipairs(view.columns) do
		if api.nvim_buf_is_valid(column.buf) and (not only or only == column.buf) then
			api.nvim_buf_clear_namespace(column.buf, ns, 0, -1)
			local count = 0
			for row, line in ipairs(api.nvim_buf_get_lines(column.buf, 0, -1, false)) do
				if vim.trim(line) ~= "" then
					count = count + 1
				end
				local item = view.registry[line:match("^(%S+)  ")]
				if item then
					api.nvim_buf_set_extmark(
						column.buf,
						ns,
						row - 1,
						0,
						{ virt_text = { { detail(item.entry, column.name), "Comment" } }, virt_text_pos = "eol" }
					)
				end
			end
			for _, win in ipairs(vim.fn.win_findbuf(column.buf)) do
				vim.wo[win].conceallevel, vim.wo[win].concealcursor = 2, "nvic"
				local title = edit.title((view.board.metadata or {}).title or "Board")
				local archived = (view.board.metadata or {}).archived and " [archived]" or ""
				local errors = #view.board.diagnostics > 0 and " [diagnostics: g?]" or ""
				vim.wo[win].winbar = (
					title
					.. archived
					.. " · "
					.. column.name
					.. " ("
					.. count
					.. ")"
					.. (view.stale and " [stale]" or "")
					.. errors
				):gsub("%%", "%%%%")
			end
		end
	end
end

function M.bind(column, actions)
	for _, binding in ipairs(column.bindings or {}) do
		api.nvim_buf_call(column.buf, function()
			if vim.fn.maparg(binding.key, "n", false, true).callback == binding.fn then
				vim.keymap.del("n", binding.key, { buffer = column.buf })
			end
		end)
	end
	column.bindings = {}
	for name, callback in pairs(actions) do
		local key = config.options.tasks.keymaps[name]
		if key then
			vim.keymap.set(
				"n",
				key,
				callback,
				{ buffer = column.buf, silent = true, nowait = true, desc = "Aero tasks: " .. name }
			)
			table.insert(column.bindings, { key = key, fn = callback })
		end
	end
end

return M
