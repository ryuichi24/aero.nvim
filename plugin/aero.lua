if vim.g.loaded_Aero then return end
vim.g.loaded_Aero = true

local subcommands = {
	reading = function(args) require("aero").reading(args[1]) end,
	reader = function(args) require("aero").reader(args[1]) end,
	review = function(args)
		if vim.tbl_contains({ "diff", "refresh", "base", "local" }, args[1]) then
			if #args > 1 then
				vim.notify("Aero: review actions take no additional arguments", vim.log.levels.WARN)
				return
			end
			return require("aero.review").command(args[1])
		end
		if #args > 1 then
			vim.notify("Aero: use :Aero review [base-ref]", vim.log.levels.WARN)
			return
		end
		require("aero").review(nil, args[1])
	end,
	reference = function() require("aero.reference").open() end,
	toggle = function() require("aero").toggle() end,
	open = function() require("aero").open() end,
	close = function() require("aero").close() end,
	refresh = function() require("aero").refresh() end,
	collapse = function(args)
		if #args > 1 then
			vim.notify(
				"Aero: use :Aero collapse [all|workspaces|worktrees|reports|exports|boards|reference]",
				vim.log.levels.WARN
			)
			return
		end
		require("aero").collapse(args[1])
	end,
	pull = function() require("aero").pull() end,
	pick = function(args)
		if #args > 1 or args[1] and args[1] ~= "current" then
			vim.notify("Aero: use :Aero pick [current]", vim.log.levels.WARN)
			return
		end
		require("aero").pick(args[1])
	end,
	new = function() require("aero").new() end,
	sessions = function() require("aero").sessions() end,
	inbox = function() require("aero").inbox() end,
	todos = function() require("aero.acp.todo_notifications").focus() end,
	companion = function(args) require("aero.companion").command(args[1]) end,
	workspaces = function() require("aero").workspaces() end,
	worktrees = function() require("aero").worktrees() end,
	resume = function(args) require("aero").resume(args[1]) end,
	panel = function() require("aero").panel() end,
	fullscreen = function() require("aero").fullscreen() end,
	prompt = function(args)
		if #args > 1 or args[1] and args[1] ~= "send" then
			vim.notify("Aero: use :Aero prompt [send]", vim.log.levels.WARN)
			return
		end
		require("aero").prompt(args[1])
	end,
	file = function() require("aero").file() end,
	prompts = function() require("aero").prompts() end,
	snippet = function(args)
		if #args > 2 then
			vim.notify("Aero: use :Aero snippet [global|workspace] [filename]", vim.log.levels.WARN)
			return
		end
		require("aero.prompt_snippet_files").new(args[1], args[2])
	end,
	cancel = function() require("aero").cancel() end,
	usage = function() require("aero").usage() end,
	report = function() require("aero").report() end,
	board = function(args)
		if #args > 2 or args[2] and args[1] ~= "markdown" and args[1] ~= "work" then
			vim.notify("Aero: use :Aero board [new|markdown|work] [board-id]", vim.log.levels.WARN)
			return
		end
		require("aero").board(args[1], nil, args[2])
	end,
	ticket = function(args)
		if args[1] == "work" then return require("aero.tasks.agent").work(args[2], args[3]) end
		require("aero").ticket(args[1])
	end,
	tasks = function(args)
		if args[1] == "install" then return require("aero.tasks.install").install() end
		vim.notify("Aero: use :Aero tasks install", vim.log.levels.WARN)
	end,
	quote = function(_, opts) require("aero").quote(opts.range > 0 and { opts.line1, opts.line2 } or nil) end,
	term = function(args)
		if args[1] == "history" and #args == 1 then return require("aero.terminal").history() end
		if #args > 0 then
			vim.notify("Aero: use :Aero term [history]", vim.log.levels.WARN)
			return
		end
		require("aero").terminal()
	end,
	add = function(args) require("aero").add_workspace(args[1]) end,
}

vim.api.nvim_create_user_command("Aero", function(opts)
	local args = opts.fargs
	local sub = table.remove(args, 1) or "toggle"
	if sub == "context" then sub = "reference" end -- legacy command alias
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
		if words[2] == "reading" and (#words > 2 or cmdline:match("%s$")) then
			return vim.tbl_filter(
				function(s) return vim.startswith(s, arglead) end,
				{ "new", "add", "edit", "next", "toggle", "note" }
			)
		end
		if words[2] == "pick" and (#words > 2 or cmdline:match("%s$")) then
			if #words > 3 or (#words == 3 and cmdline:match("%s$")) then return {} end
			return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, { "current" })
		end
		if words[2] == "term" and (#words > 2 or cmdline:match("%s$")) then
			return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, { "history" })
		end
		if words[2] == "review" and (#words > 2 or cmdline:match("%s$")) then
			if #words > 3 or (#words == 3 and cmdline:match("%s$")) then return {} end
			return vim.tbl_filter(
				function(s) return vim.startswith(s, arglead) end,
				{ "diff", "refresh", "base", "local" }
			)
		end
		if words[2] == "reader" and (#words > 2 or cmdline:match("%s$")) then
			return vim.tbl_filter(
				function(s) return vim.startswith(s, arglead) end,
				{ "tabs", "panes", "source", "exports", "references", "reports" }
			)
		end
		if words[2] == "prompt" and (#words > 2 or cmdline:match("%s$")) then
			if #words > 3 or (#words == 3 and cmdline:match("%s$")) then return {} end
			return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, { "send" })
		end
		if words[2] == "snippet" and (#words > 2 or cmdline:match("%s$")) then
			if #words > 3 or (#words == 3 and cmdline:match("%s$")) then return {} end
			return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, { "global", "workspace" })
		end
		if words[2] == "collapse" and (#words > 2 or cmdline:match("%s$")) then
			return vim.tbl_filter(
				function(s) return vim.startswith(s, arglead) end,
				{ "all", "workspaces", "worktrees", "reports", "exports", "boards", "reference" }
			)
		end
		if words[2] == "companion" and (#words > 2 or cmdline:match("%s$")) then
			return vim.tbl_filter(
				function(s) return vim.startswith(s, arglead) end,
				{ "install", "start", "stop", "pair", "devices", "revoke" }
			)
		end
		if words[2] == "tasks" and (#words > 2 or cmdline:match("%s$")) then
			return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, { "install" })
		end
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
			return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, choices)
		end
		if #words >= 2 and words[2] == "add" and (#words > 2 or cmdline:match("%s$")) then
			return vim.fn.getcompletion(arglead, "dir")
		end
		return vim.tbl_filter(function(s) return s:find(arglead, 1, true) == 1 end, vim.tbl_keys(subcommands))
	end,
	desc = "Aero: workspaces, worktrees and agent sessions",
})
