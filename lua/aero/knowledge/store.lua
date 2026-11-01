-- Versioned knowledge state shared by ingestion and research workflows.
local M = {}

function M.script(name)
	return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))))
		.. "/apps/scripts/"
		.. name
end

function M.directory()
	return vim.fs.dirname(require("aero.config").options.state_file) .. "/knowledge"
end

function M.executable()
	local options = require("aero.config").options
	local requested = options.knowledge.executable or options.tasks.agent.executable

	if type(requested) ~= "string" or requested == "" then
		local local_build = vim.fs.normalize(M.script("../mcp/aero-mcp"))
		requested = vim.fn.executable(local_build) == 1 and local_build or nil
	end

	return require("aero.tasks.install").resolve(requested)
end

function M.id()
	return (vim.uv.random(16):gsub(".", function(byte)
		return ("%02x"):format(byte:byte())
	end))
end

function M.name(value)
	assert(
		type(value) == "string" and vim.trim(value) ~= "" and not value:find("%c"),
		"use a nonempty single-line name"
	)
	return vim.trim(value)
end

function M.find(items, key)
	for _, item in ipairs(items or {}) do
		if item.id == key then
			return item
		end
	end

	error("knowledge item no longer exists: " .. tostring(key))
end

function M.read()
	local path = M.directory() .. "/catalog.json"

	if not vim.uv.fs_stat(path) then
		return { version = 1, collections = {}, spaces = {}, jobs = {}, research_scopes = {} }
	end

	local data = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
	assert(type(data) == "table" and data.version == 1, "invalid knowledge catalog version")
	assert(vim.islist(data.collections) and vim.islist(data.spaces), "invalid knowledge catalog lists")
	data.jobs = data.jobs or {}
	data.research_scopes = data.research_scopes or {}
	local ids, collections = {}, {}

	for _, collection in ipairs(data.collections) do
		assert(
			type(collection.id) == "string" and collection.id:match("^%x+$") and not ids[collection.id],
			"invalid collection ID"
		)
		M.name(collection.name)
		ids[collection.id], collections[collection.id] = true, true
	end

	for _, space in ipairs(data.spaces) do
		assert(type(space.id) == "string" and space.id:match("^%x+$") and not ids[space.id], "invalid space ID")
		assert(collections[space.collection_id], "space references missing collection")
		M.name(space.name)
		assert(vim.islist(space.sources), "invalid source list")
		ids[space.id] = true
		space.notes, space.folders = space.notes or {}, space.folders or {}
		space.source_sets = space.source_sets or {}

		for _, source in ipairs(space.sources) do
			assert(type(source.id) == "string" and source.id:match("^%x+$"), "invalid source ID")
			assert(source.path == "spaces/" .. space.id .. "/sources/" .. source.id, "invalid source path")

			if
				source.status == "needs_attention"
				and source.extraction
				and not source.error
				and #(source.issues or {}) > 0
			then
				source.status = "ready_with_warnings"
			end
		end
	end

	return data
end

function M.catalog()
	local ok, data = pcall(M.read)

	if not ok then
		return nil, tostring(data)
	end

	return data
end

function M.atomic(path, content)
	assert(require("aero.atomic_file").write(path, content))
end

function M.update(callback)
	return require("aero.state_lock").with_lock(M.directory() .. "/catalog.json", function()
		local data = M.read()
		local result = callback(data)
		M.atomic(M.directory() .. "/catalog.json", vim.json.encode(data))
		vim.schedule(function()
			local dashboard = package.loaded["aero.dashboard"]

			if dashboard then
				dashboard.render()
			end

			local panel = package.loaded["aero.panel"]

			if panel then
				panel.refresh()
			end
		end)
		return result
	end)
end

function M.scope(data, scope)
	assert(type(scope) == "table", "select a knowledge scope")
	local spaces = {}

	if scope.space_id then
		table.insert(spaces, M.find(data.spaces, scope.space_id))
	elseif scope.collection_id then
		M.find(data.collections, scope.collection_id)

		for _, space in ipairs(data.spaces) do
			if space.collection_id == scope.collection_id then
				table.insert(spaces, space)
			end
		end
	elseif scope.collection_ids then
		assert(vim.islist(scope.collection_ids) and #scope.collection_ids > 0, "explicitly select collections")
		local selected = {}

		for _, collection_id in ipairs(scope.collection_ids) do
			M.find(data.collections, collection_id)
			selected[collection_id] = true
		end

		for _, space in ipairs(data.spaces) do
			if selected[space.collection_id] then
				table.insert(spaces, space)
			end
		end
	else
		error("scope requires a space, collection, or explicit collection selection")
	end

	return spaces
end

return M
