-- Optional, server-side source restrictions. Paths are resolved before comparison.
local M = {}
local storage = require("aero.storage")

function M.options()
	return require("aero.config").options.companion.reference_finder
end

function M.roots()
	local roots = M.options().roots

	if roots == false then
		return {}
	end

	if type(roots) ~= "table" then
		return nil, "companion.reference_finder.roots must be false or a list of directories"
	end

	local paths = {}

	for _, root in ipairs(roots) do
		if type(root) ~= "string" or root == "" then
			return nil, "invalid reference source root"
		end

		table.insert(paths, storage.canonical(vim.fn.expand(root)))
	end

	return paths
end

function M.allowed(path)
	if M.options().roots == false then
		return true
	end

	local roots, err = M.roots()

	if not roots then
		return nil, err
	end

	if #roots == 0 then
		return nil,
			"remote reference browsing/imports are disabled; configure companion.reference_finder.roots to allow source directories"
	end

	local canonical = storage.canonical(path)

	for _, root in ipairs(roots) do
		if root == "/" or canonical == root or storage.inside(canonical, root) then
			return true
		end
	end

	return nil, "source is outside the allowed companion reference roots"
end

return M
