-- Upgrade JSON metadata under its writer lock, preserving the original on failure.
local M = {}

function M.read(path, upgrade, locked)
	local function read()
		local file, err, code = io.open(path, "r")

		if not file then
			return nil, code ~= 2 and err or nil
		end

		local content = file:read("*a")
		file:close()
		local ok, data, changed = pcall(function()
			local decoded, value = pcall(vim.json.decode, content)
			assert(decoded and type(value) == "table", "invalid state JSON: " .. path)
			return upgrade(value)
		end)

		if not ok then
			return nil, tostring(data)
		end

		return data, nil, changed
	end

	local function migrate()
		local data, err, changed = read()

		if data and changed then
			local ok, save_err = require("aero.atomic_file").write(path, vim.json.encode(data))

			if not ok then
				return nil, save_err
			end
		end

		return data, err
	end

	if locked then
		return migrate()
	end

	local data, err, changed = read()

	if not data or not changed then
		return data, err
	end

	-- Re-read after acquiring the lock: another instance may have migrated or edited it.
	return require("aero.state_lock").with_lock(path, migrate)
end

return M
