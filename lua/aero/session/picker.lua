-- Session selection owns enumeration and labels; callers may supply navigation and caches.
local session = require("aero.session")
local M = {}

function M.open(scope, opts)
	opts = opts or {}
	local choices = {}

	if scope == "current" then
		local path = vim.t.aero_worktree or vim.fn.getcwd()

		for _, selected in ipairs(session.list(path)) do
			table.insert(choices, { session = selected })
		end
	else
		for _, repository in ipairs(require("aero.repositories").list(opts.load_worktrees, scope == "all")) do
			for _, worktree in ipairs(repository.list) do
				for _, selected in ipairs(session.list(worktree.path)) do
					table.insert(choices, { ws = repository.ws, wt = worktree, session = selected })
				end
			end
		end
	end

	if #choices == 0 then
		vim.notify("Aero: no sessions", vim.log.levels.INFO)
		return
	end

	vim.ui.select(choices, {
		prompt = "Agent session",
		format_item = function(choice)
			local selected = choice.session
			local activity = session.activity(selected)
			local suffix = activity and "  " .. activity or ""

			if scope == "current" then
				return ("%s %s [%s]%s"):format(session.icon(selected), selected.name, selected.agent, suffix)
			end

			local label = choice.wt.branch or "(detached " .. (choice.wt.head or ""):sub(1, 7) .. ")"
			return ("%s %s / %s / %s%s"):format(session.icon(selected), choice.ws.name, label, selected.name, suffix)
		end,
	}, function(choice)
		if not choice then
			return
		end

		require("aero.scenes").activate(choice.session)

		if opts.open_session then
			opts.open_session(choice.session)
		else
			require("aero.navigation").open_session(choice.session, "default")
		end
	end)
end

return M
