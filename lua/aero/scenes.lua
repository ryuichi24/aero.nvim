-- Scenes organize shared repositories and scene-owned conversations and collections.
local M = {}
local store = require("aero.store")
local tabs = {}

function M.current()
	return store.data.active_scene or "default"
end

function M.list()
	return store.data.scenes or { { id = "default", name = "Default" } }
end

function M.find(key, data)
	for _, scene in ipairs(data and data.scenes or M.list()) do
		if scene.id == key or scene.name == key then
			return scene
		end
	end
end

function M.workspaces(all)
	if all then
		return store.data.workspaces
	end

	local workspaces = vim.tbl_filter(function(ws)
		return vim.tbl_contains(ws.scene_ids or { "default" }, M.current())
	end, store.data.workspaces)
	local scene = M.find(M.current())

	if scene and scene.id ~= "default" then
		return vim.tbl_map(function(ws)
			local expanded = (scene.workspace_expanded or {})[ws.root] ~= false
			return vim.tbl_extend("force", ws, { expanded = expanded })
		end, workspaces)
	end

	return workspaces
end

function M.owns(item, scene_id)
	local owner = item.scene_id or "default"

	if not M.find(owner) then
		owner = "default"
	end

	return owner == (scene_id or M.current())
end

local function title(value)
	if type(value) ~= "string" or vim.trim(value) == "" or value:find("%c") then
		return nil, "use a nonempty single-line scene name"
	end

	return vim.trim(value)
end

local function changed()
	require("aero.events").emit("scenes_changed", { scene_id = M.current() })
	local dashboard = package.loaded["aero.dashboard"]

	if dashboard then
		dashboard.refresh()
	end
end

function M.create(name)
	local valid, err = title(name)

	if not valid then
		return nil, err
	end

	local result, save_err = store.update_scenes(function(data)
		if M.find(valid, data) then
			return nil, "a scene with that name already exists"
		end

		local scene = {
			id = vim.uv.random(16):gsub(".", function(byte)
				return ("%02x"):format(byte:byte())
			end),
			name = valid,
		}
		table.insert(data.scenes, scene)
		return scene
	end)

	if result then
		changed()
	end

	return result, save_err
end

function M.rename(key, name)
	local valid, err = title(name)

	if not valid then
		return nil, err
	end

	local result, save_err = store.update_scenes(function(data)
		local scene, duplicate = M.find(key, data), M.find(valid, data)

		if not scene then
			return nil, "scene no longer exists"
		elseif duplicate and duplicate.id ~= scene.id then
			return nil, "a scene with that name already exists"
		end

		scene.name = valid
		return scene
	end)

	if result then
		changed()
	end

	return result, save_err
end

function M.membership(root, present, key)
	local result, err = store.update_scenes(function(data)
		local scene = M.find(key or M.current(), data)
		local ws = store.find_workspace(root)

		if not scene or not ws then
			return nil, "scene or workspace no longer exists"
		end

		local ids = vim.tbl_filter(function(id)
			return id ~= scene.id
		end, ws.scene_ids or { "default" })

		if present then
			table.insert(ids, scene.id)
		end

		ws.scene_ids = ids
		return true
	end)

	if result then
		changed()
	end

	return result, err
end

--- Resolve session membership without changing the global runtime session registry.
function M.contains(s, scene_id)
	scene_id = scene_id or M.current()
	local definition = store.find_session(s.worktree, s.name) or {}

	if s.worktree == require("aero.general").directory() then
		return M.owns(definition, scene_id)
	end

	local scope = require("aero.knowledge.agent").scope(s)

	if scope then
		local data = require("aero.knowledge.store").catalog()
		local ids = scope.collection_ids or { scope.collection_id }

		if scope.space_id then
			for _, space in ipairs(data and data.spaces or {}) do
				if space.id == scope.space_id then
					ids = { space.collection_id }
				end
			end
		end

		for _, collection in ipairs(data and data.collections or {}) do
			if vim.tbl_contains(ids, collection.id) and M.owns(collection, scene_id) then
				return true
			end
		end

		return false
	end

	local root = require("aero.git").main_root(s.worktree)
	local ws = root and store.find_workspace(root)

	if root and not ws then
		for _, candidate in ipairs(store.data.workspaces) do
			if (vim.uv.fs_realpath(candidate.root) or candidate.root) == root then
				ws = candidate
				break
			end
		end
	end

	if ws then
		return vim.tbl_contains(ws.scene_ids or { "default" }, scene_id)
	end

	local ancestry = require("aero.submodules").ancestry(s.worktree)

	if ancestry then
		return M.contains({ worktree = ancestry.worktree }, scene_id)
	end

	return M.owns(definition, scene_id)
end

local function remember()
	local selected = require("aero.panel").current_session()
	local worktree = vim.t.aero_worktree

	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
		local shown = require("aero.session").from_buf(vim.api.nvim_win_get_buf(win))

		if shown and M.contains(shown) then
			selected = shown
			break
		end
	end

	if selected and M.contains(selected) then
		return { worktree = selected.worktree, session = selected.name }
	elseif worktree and M.contains({ worktree = worktree }) then
		return { worktree = worktree }
	end
end

function M.switch(key)
	local previous, last = M.current(), remember()
	require("aero.dashboard").save_scene()
	local result, err = store.update_scenes(function(data)
		local scene = M.find(key, data)

		if not scene then
			return nil, "scene no longer exists"
		end

		local old = M.find(previous, data)

		if old and last then
			old.last = last
		end

		data.active_scene = scene.id
		return scene
	end)

	if not result then
		return nil, err
	elseif result.id == previous then
		return true
	end

	tabs[previous] = vim.api.nvim_get_current_tabpage()
	local dashboard = require("aero.dashboard")
	dashboard.scene_changed()
	local saved = result.last
	local selected

	if saved and saved.session then
		for _, s in ipairs(require("aero.session").list(saved.worktree)) do
			if s.name == saved.session and M.contains(s) then
				selected = s
			end
		end
	end

	if selected and selected.worktree == require("aero.general").directory() then
		require("aero.general").show(selected)
	elseif selected and require("aero.knowledge.agent").scope(selected) then
		require("aero.knowledge.agent").show(selected)
	elseif saved and M.contains({ worktree = saved.worktree }) and vim.fn.isdirectory(saved.worktree) == 1 then
		dashboard.open_worktree(saved.worktree)

		if selected then
			require("aero.navigation").open_session(selected, "default")
		end
	elseif tabs[result.id] and vim.api.nvim_tabpage_is_valid(tabs[result.id]) then
		vim.api.nvim_set_current_tabpage(tabs[result.id])
	else
		vim.cmd.tabnew()
		tabs[result.id] = vim.api.nvim_get_current_tabpage()
		local directory = vim.fs.dirname(require("aero.config").options.state_file) .. "/scenes/" .. result.id
		vim.fn.mkdir(directory, "p")
		vim.cmd("tcd " .. vim.fn.fnameescape(directory))
	end

	dashboard.open()
	changed()
	require("aero.events").emit("scene_switched", { scene_id = result.id, previous_scene_id = previous })
	return true
end

--- Reassign owned content before removing the scene; paths and live sessions stay stable.
function M.delete(key)
	local scene = M.find(key)

	if not scene then
		return nil, "scene no longer exists"
	elseif scene.id == "default" then
		return nil, "the Default scene cannot be deleted"
	end

	if scene.id == M.current() then
		local ok, err = M.switch("default")

		if not ok then
			return nil, err
		end
	end

	local result, save_err = store.update_scenes(function(data)
		-- Lock order is state then catalog. Keep the scene if the catalog cannot be saved.
		local moved, err = require("aero.knowledge.store").update(function(catalog)
			for _, collection in ipairs(catalog.collections) do
				if collection.scene_id == scene.id then
					collection.scene_id = "default"
				end
			end

			return true
		end)

		if not moved then
			return nil, err
		end

		data.scenes = vim.tbl_filter(function(item)
			return item.id ~= scene.id
		end, data.scenes)

		for _, ws in ipairs(data.workspaces) do
			ws.scene_ids = vim.tbl_filter(function(id)
				return id ~= scene.id
			end, ws.scene_ids or { "default" })

			if #ws.scene_ids == 0 then
				ws.scene_ids = { "default" }
			end
		end

		for _, list in pairs(data.sessions) do
			for _, definition in ipairs(list) do
				if definition.scene_id == scene.id then
					definition.scene_id = "default"
				end
			end
		end

		return true
	end)

	if result then
		tabs[scene.id] = nil
		changed()
	end

	return result, save_err
end

local function report(result, err)
	if not result and err then
		vim.notify("Aero: " .. err, vim.log.levels.WARN)
	end

	return result
end

function M.open()
	store.load()
	require("aero.picker").open({
		title = "scenes · n new · r rename · d delete",
		items = M.list,
		label = function(scene)
			return (scene.id == M.current() and "● " or "  ") .. scene.name
		end,
		select = function(scene)
			report(M.switch(scene.id))
		end,
		actions = {
			n = function()
				require("aero.picker").close()
				M.command({ "new" })
			end,
			r = function(scene)
				require("aero.picker").close()
				M.command({ "rename", scene.id })
			end,
			d = function(scene)
				if
					vim.fn.confirm("Delete scene " .. scene.name .. "? Content moves to Default.", "&Yes\n&No", 2) == 1
				then
					report(M.delete(scene.id))
				end
			end,
		},
	})
end

--- Cross-scene navigation follows the selected item into one of its scenes.
function M.activate(s)
	if M.contains(s) then
		return true
	end

	for _, scene in ipairs(M.list()) do
		if M.contains(s, scene.id) then
			return M.switch(scene.id)
		end
	end

	return true
end

function M.setup()
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = vim.api.nvim_create_augroup("Aero.scenes", { clear = true }),
		callback = function()
			local last, current = remember(), M.current()

			if last then
				store.update_scenes(function(data)
					local scene = M.find(current, data)

					if scene then
						scene.last = last
					end
				end)
			end
		end,
	})
end

function M.command(args)
	local action = args[1]

	if not action then
		return M.open()
	elseif action == "switch" then
		if args[2] then
			return report(M.switch(table.concat(args, " ", 2)))
		end

		return M.open()
	elseif action == "new" then
		local function create(value)
			if value then
				local scene = report(M.create(value))

				if scene then
					report(M.switch(scene.id))
				end
			end
		end

		if args[2] then
			return create(table.concat(args, " ", 2))
		end

		return vim.ui.input({ prompt = "New scene: " }, create)
	elseif action == "rename" then
		local scene = M.find(args[2] and table.concat(args, " ", 2) or M.current())

		if scene then
			return vim.ui.input({ prompt = "Rename scene: ", default = scene.name }, function(value)
				if value then
					report(M.rename(scene.id, value))
				end
			end)
		end
	elseif action == "delete" then
		local scene = M.find(args[2] and table.concat(args, " ", 2) or M.current())

		if
			scene
			and vim.fn.confirm("Delete scene " .. scene.name .. "? Content moves to Default.", "&Yes\n&No", 2) == 1
		then
			return report(M.delete(scene.id))
		end
	elseif action == "add" or action == "remove" then
		local present = action == "add"
		return vim.ui.select(store.data.workspaces, {
			prompt = present and "Add workspace to scene" or "Remove workspace from scene",
			format_item = function(ws)
				return ws.name .. "  " .. ws.root
			end,
		}, function(ws)
			if ws then
				report(M.membership(ws.root, present))
			end
		end)
	else
		return report(nil, "use :Aero scene [new|switch|rename|delete|add|remove]")
	end
end

return M
