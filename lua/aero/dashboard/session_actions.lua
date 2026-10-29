-- Session actions accept explicit selections; the dashboard retains view state.
local config = require("aero.config")
local session = require("aero.session")
local navigation = require("aero.navigation")
local panel = require("aero.panel")
local M = {}

local function notify(message)
	vim.notify("Aero: " .. message, vim.log.levels.WARN)
end

local function session_name(name)
	if not name or vim.trim(name) == "" then
		return
	end

	name = vim.trim(name)

	if name:find("%c") then
		notify("use a session name without control characters")
		return
	end

	return name
end

function M.start(item, agent, on_created)
	if not (item and item.wt) then
		notify("move the cursor to a worktree first")
		return
	end

	local function create(name)
		local selected, err = session.create(item.wt.path, agent, name)

		if not selected then
			notify(err)
			return
		end

		on_created(selected)
		navigation.open_session(selected, "default")
	end

	if not config.options.prompt_session_name then
		return create()
	end

	require("aero.input").input({ prompt = "New session name: ", default = agent }, function(value)
		local name = session_name(value)

		if name then
			create(name)
		end
	end)
end

function M.choose(item, label, on_created)
	local names = vim.tbl_keys(config.options.agents)
	table.sort(names)
	table.insert(names, 1, "default")
	local worktree = item.wt
	label = label or worktree.branch or "(detached " .. (worktree.head or ""):sub(1, 7) .. ")"
	vim.ui.select(names, {
		prompt = "New agent for " .. label,
		format_item = function(name)
			return name == "default" and ("default (" .. config.options.default_agent .. ")") or name
		end,
	}, function(choice, index)
		if choice then
			if index == 1 or (index == nil and choice == "default") then
				choice = config.options.default_agent
			end

			M.start(item, choice, on_created)
		end
	end)
end

function M.rename(selected, changed)
	require("aero.input").input({ prompt = "Rename session: ", default = selected.name }, function(value)
		local name = session_name(value)

		if not name then
			return
		end

		local ok, err = session.rename(selected, name)

		if not ok then
			notify(err)
		elseif changed then
			changed()
		end
	end)
end

--- Return the destination window only after a successful restart.
function M.restart(selected, code_window)
	local use_panel = panel.enabled() and config.options.dashboard.position ~= "current"

	if use_panel and not navigation.enter_worktree(selected.worktree) then
		return
	end

	local win = session.prepare_win(use_panel and panel.open() or code_window())

	if session.start(selected, win, true) then
		if use_panel then
			panel.shown(selected)
		end

		return win, use_panel
	end
end

function M.delete(selected)
	local prompt = (selected.job and "Kill running session " or "Delete session ") .. selected.name .. "?"

	if vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1 then
		return session.delete(selected)
	end
end

return M
