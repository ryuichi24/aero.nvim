-- Dashboard bindings and their help share one description catalog.
local api = vim.api
local config = require("aero.config")
local M = {}
local bindings = {}
local descriptions = {
	open = "open session or report / toggle node",
	expand = "expand node / open session or report",
	collapse = "collapse node / go to parent",
	toggle = "toggle node",
	open_vsplit = "open session or report in vsplit",
	open_split = "open session or report in split",
	open_tab = "open session or report in tab",
	add = "add: worktree / agent session / report (on Reports)",
	add_workspace = "add workspace",
	delete = "delete selected item: session (confirm) / report (confirm) / worktree / workspace",
	rename = "rename selected session, report, or board",
	move = "move selected report to another worktree",
	yank_name = "copy selected item name",
	yank_path = "copy selected item absolute path",
	stop = "stop session",
	restart = "restart session (resume)",
	refresh = "refresh git worktrees",
	pull = "pull worktree upstream (fast-forward only)",
	switch_branch = "switch worktree branch",
	review = "review worktree changes",
	cd = ":tcd to worktree",
	edit = "browse worktree source (Oil or directory browser)",
	open_board_markdown = "open selected board's raw Markdown file",
	edit_enter = "open worktree / restore last code buffer",
	edit_mouse = "open clicked worktree / restore last code buffer",
	terminal = "open worktree terminal",
	next_workspace = "next workspace",
	prev_workspace = "previous workspace",
	close = "close dashboard",
	help = "show this help",
}

function M.help()
	local lines = {}
	local keys = config.options.keymaps
	local names = vim.tbl_keys(descriptions)
	table.sort(names)

	for _, name in ipairs(names) do
		if keys[name] then
			table.insert(lines, ("  %-8s %s"):format(keys[name], descriptions[name]))
		end
	end

	if config.options.fullscreen_key then
		table.insert(lines, ("  %-8s toggle fullscreen"):format(config.options.fullscreen_key))
	end

	if config.options.quote_key then
		table.insert(
			lines,
			("  %-8s quote selection (Visual mode in code / agent logs)"):format(config.options.quote_key)
		)
	end

	local agents = vim.tbl_keys(config.options.agents)
	table.sort(agents)

	for _, name in ipairs(agents) do
		local key = config.options.agents[name].key

		if key then
			table.insert(lines, ("  %-8s open %s on worktree"):format(key, name))
		end
	end

	local width = 0

	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
	end

	local buf = api.nvim_create_buf(false, true)
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = #lines,
		row = math.floor((vim.o.lines - #lines) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " Aero ",
	})

	for _, key in ipairs({ "q", "<Esc>", "g?" }) do
		vim.keymap.set("n", key, function()
			api.nvim_win_close(win, true)
		end, { buffer = buf, nowait = true })
	end
end

function M.apply(buf, actions, start_agent)
	if not buf or not api.nvim_buf_is_valid(buf) then
		return
	end

	for _, binding in ipairs(bindings[buf] or {}) do
		api.nvim_buf_call(buf, function()
			local current = vim.fn.maparg(binding.lhs, "n", false, true)

			if current.callback == binding.callback then
				vim.keymap.del("n", binding.lhs, { buffer = buf })
			end
		end)
	end

	if not bindings[buf] then
		api.nvim_create_autocmd("BufWipeout", {
			buffer = buf,
			once = true,
			callback = function()
				bindings[buf] = nil
			end,
		})
	end

	bindings[buf] = {}
	local keys = config.options.keymaps

	local function map(lhs, callback, description)
		if lhs then
			vim.keymap.set(
				"n",
				lhs,
				callback,
				{ buffer = buf, nowait = true, silent = true, desc = "Aero: " .. description }
			)
			table.insert(bindings[buf], { lhs = lhs, callback = callback })
		end
	end

	for name, callback in pairs(actions) do
		if name ~= "open" then
			map(keys[name], callback, descriptions[name] or name)
		end
	end

	for _, entry in ipairs({
		{ "open", "default" },
		{ "open_vsplit", "vsplit" },
		{ "open_split", "split" },
		{ "open_tab", "tab" },
	}) do
		map(keys[entry[1]], function()
			actions.open(entry[2])
		end, descriptions[entry[1]])
	end

	for name, agent in pairs(config.options.agents) do
		map(agent.key, function()
			start_agent(name)
		end, "open " .. name)
	end
end

return M
