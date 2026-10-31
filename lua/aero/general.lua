-- Workspace-independent ACP conversations, using the regular transcript and composer.
local M = {}
local session = require("aero.session")
local store = require("aero.store")
local config = require("aero.config")
local view = require("aero.conversation_view").new()

function M.directory()
	return vim.fs.dirname(config.options.state_file) .. "/general"
end

local function notify(err)
	vim.notify("Aero: " .. tostring(err), vim.log.levels.WARN)
end

function M.show(s)
	return view.show(s, { directory = M.directory() })
end

function M.new(requested_agent)
	local actions = require("aero.dashboard.session_actions")
	local item = { wt = { path = M.directory() } }
	local function created()
		vim.fn.mkdir(M.directory(), "p")
	end

	local function open(s)
		M.show(s)
		session.enter(s)
	end

	if requested_agent then
		return actions.start(item, requested_agent, created, open)
	end

	return actions.choose(item, "General", created, open)
end

local function text(s)
	local saved = s.chat or require("aero.history").load(s) or {}
	local lines = {}

	for _, block in ipairs(saved.blocks or {}) do
		if type(block.text) == "string" then
			table.insert(lines, block.text)
		end
	end

	return table.concat(lines, "\n\n")
end

function M.history(archived)
	store.load()
	local items = session.list(M.directory())
	local content = {}

	for _, s in ipairs(items) do
		content[s.key] = text(s)
	end

	local function definition(s)
		return store.find_session(s.worktree, s.name) or {}
	end

	local function field(s, name)
		local ok, err = store.set_session_field(s.worktree, s.name, name, not definition(s)[name])

		if not ok then
			notify(err)
		end
	end

	require("aero.picker").open({
		title = archived and "archived general conversations"
			or "general conversations · p pin · a archive · r rename",
		filetype = "aero_general_history",
		items = function()
			return vim.tbl_filter(function(s)
				return (definition(s).archived == true) == (archived == true)
			end, items)
		end,
		label = function(s)
			return (definition(s).pinned and "★ " or "  ") .. s.name .. " [" .. s.agent .. "]"
		end,
		search = function(s)
			return s.name .. " " .. s.agent .. " " .. content[s.key]
		end,
		preview = function(s)
			return content[s.key]
		end,
		sort = function(a, b)
			local ap, bp = definition(a).pinned == true, definition(b).pinned == true

			if ap ~= bp then
				return ap
			end

			return a.name < b.name
		end,
		select = M.show,
		actions = {
			p = function(s)
				field(s, "pinned")
			end,
			a = function(s)
				field(s, "archived")
			end,
			r = function(s)
				require("aero.picker").close()
				vim.ui.input({ prompt = "Conversation name: ", default = s.name }, function(name)
					if name and vim.trim(name) ~= "" then
						local ok, err = session.rename(s, vim.trim(name))

						if not ok then
							notify(err)
						end
					end

					M.history(archived)
				end)
			end,
		},
	})
end

function M.command(action)
	if action == "new" then
		return M.new()
	elseif action == nil or action == "history" or action == "archived" then
		return M.history(action == "archived")
	end

	notify("use :Aero general [new|history|archived]")
end

return M
