-- Persist only explicit fold changes; defaults and unrelated runtime state stay local.
local store = require("aero.store")
local M = {}
local headings = { "workspace_open", "general_open", "knowledge_open" }
local sections = {
	"expanded",
	"reports_expanded",
	"reading_expanded",
	"reference_expanded",
	"reference_folders_expanded",
	"exports_expanded",
	"sessions_expanded",
	"boards_expanded",
	"submodules_expanded",
	"repositories_expanded",
	"knowledge_expanded",
}
local previous = {}

local function snapshot(state)
	local result = {}

	for _, name in ipairs(headings) do
		result[name] = state[name]
	end

	for _, name in ipairs(sections) do
		result[name] = vim.deepcopy(state[name])
	end

	return result
end

function M.restore(state)
	local saved = store.data.sidebar or {}
	local scenes = require("aero.scenes")
	local scene = scenes.find(scenes.current())

	if scene and scene.id ~= "default" then
		saved = scene.sidebar or {}
	end

	for _, name in ipairs(headings) do
		state[name] = nil

		if type(saved[name]) == "boolean" then
			state[name] = saved[name]
		end
	end

	for _, name in ipairs(sections) do
		state[name] = {}

		for key, value in pairs(type(saved[name]) == "table" and saved[name] or {}) do
			if type(value) == "boolean" then
				state[name][key] = value
			end
		end
	end

	previous = snapshot(state)
end

function M.save(state)
	local current = snapshot(state)
	local changes = {}

	for _, name in ipairs(headings) do
		if current[name] ~= previous[name] then
			changes[name] = current[name] == nil and vim.NIL or current[name]
		end
	end

	for _, name in ipairs(sections) do
		local delta = {}

		for key, value in pairs(current[name]) do
			if value ~= (previous[name] or {})[key] then
				delta[key] = value
			end
		end

		for key in pairs(previous[name] or {}) do
			if current[name][key] == nil then
				delta[key] = vim.NIL
			end
		end

		if next(delta) then
			changes[name] = delta
		end
	end

	if not next(changes) or store.set_sidebar(changes) then
		previous = current
	end
end

return M
