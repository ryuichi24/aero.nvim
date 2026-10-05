if vim.g.loaded_Aero then
	return
end
vim.g.loaded_Aero = true

local subcommands = {
	toggle = function()
		require("aero").toggle()
	end,
	open = function()
		require("aero").open()
	end,
	close = function()
		require("aero").close()
	end,
	refresh = function()
		require("aero").refresh()
	end,
	pull = function()
		require("aero").pull()
	end,
	pick = function()
		require("aero").pick()
	end,
	sessions = function()
		require("aero").sessions()
	end,
	resume = function(args)
		require("aero").resume(args[1])
	end,
	panel = function()
		require("aero").panel()
	end,
	fullscreen = function()
		require("aero").fullscreen()
	end,
	prompt = function()
		require("aero").prompt()
	end,
	cancel = function()
		require("aero").cancel()
	end,
	usage = function()
		require("aero").usage()
	end,
	report = function()
		require("aero").report()
	end,
	board = function(args)
		if #args > 2 or args[2] and args[1] ~= "markdown" and args[1] ~= "work" then
			vim.notify("Aero: use :Aero board [new|markdown|work] [board-id]", vim.log.levels.WARN)
			return
		end
		require("aero").board(args[1], nil, args[2])
	end,
	ticket = function(args)
		if args[1] == "work" then
			return require("aero.tasks.agent").work(args[2], args[3])
		end
		require("aero").ticket(args[1])
	end,
	tasks = function(args)
		if args[1] == "install" then
			return require("aero.tasks.install").install()
		end
		vim.notify("Aero: use :Aero tasks install", vim.log.levels.WARN)
	end,
	quote = function(_, opts)
		require("aero").quote(opts.range > 0 and { opts.line1, opts.line2 } or nil)
	end,
	term = function()
		require("aero").terminal()
	end,
	add = function(args)
		require("aero").add_workspace(args[1])
	end,
}

vim.api.nvim_create_user_command("Aero", function(opts)
	local args = opts.fargs
	local sub = table.remove(args, 1) or "toggle"
	local fn = subcommands[sub]
	if not fn then
		vim.notify("Aero: unknown subcommand " .. sub, vim.log.levels.ERROR)
		return
	end
	fn(args, opts)
end, {
	nargs = "*",
	range = true,
	complete = function(arglead, cmdline)
		local words = vim.split(cmdline, "%s+", { trimempty = true })
		if
			words[2] == "board"
			and (words[3] == "markdown" or words[3] == "work")
			and (#words > 3 or cmdline:match("%s$"))
		then
			return require("aero.tasks.ui").board_ids(arglead)
		end
		if #words >= 2 and (words[2] == "board" or words[2] == "ticket") and (#words > 2 or cmdline:match("%s$")) then
			local choices = words[2] == "board" and { "new", "markdown", "work" }
				or { "new", "move", "work", "removed", "recover" }
			return vim.tbl_filter(function(s)
				return vim.startswith(s, arglead)
			end, choices)
		end
		if #words >= 2 and words[2] == "add" and (#words > 2 or cmdline:match("%s$")) then
			return vim.fn.getcompletion(arglead, "dir")
		end
		return vim.tbl_filter(function(s)
			return s:find(arglead, 1, true) == 1
		end, vim.tbl_keys(subcommands))
	end,
	desc = "Aero: workspaces, worktrees and agent sessions",
})
