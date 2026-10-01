-- Per-session snapshots, kept separate from the small shared session registry.
local config = require("aero.config")
local M = {}
local pending = {}

local function path(s)
	return config.options.state_file .. ".history/" .. vim.fn.sha256(s.key) .. ".json"
end

function M.load(s)
	if not config.options.persist_sessions then
		return nil
	end
	local f = io.open(path(s), "r")
	if not f then
		return nil
	end
	local ok, data = pcall(vim.json.decode, f:read("*a"))
	f:close()
	return ok and type(data) == "table" and data or nil
end

local function write(s, snapshot)
	if not config.options.persist_sessions then
		return
	end
	local data = snapshot()
	if not data then
		return
	end
	local file = path(s)
	vim.fn.mkdir(vim.fs.dirname(file), "p")
	local tmp = file .. "." .. vim.fn.getpid() .. ".tmp"
	local f, err = io.open(tmp, "w")
	if f then
		local ok, result = f:write(vim.json.encode(data))
		f:close()
		if ok then
			ok, result = vim.uv.fs_rename(tmp, file)
		end
		if ok then
			return
		end
		err = result
		os.remove(tmp)
	end
	vim.notify("aero: can't save history: " .. tostring(err), vim.log.levels.ERROR)
end

function M.flush(s)
	local item = pending[s.key]
	if item then
		pending[s.key] = nil
		write(s, item.snapshot)
	end
end

-- Coalesce streaming updates; the snapshot is taken outside buffer callbacks/textlock.
function M.save(s, snapshot)
	if not config.options.persist_sessions then
		return
	end
	if pending[s.key] then
		pending[s.key].snapshot = snapshot
		return
	end
	local item = { s = s, snapshot = snapshot }
	pending[s.key] = item
	vim.defer_fn(function()
		if pending[s.key] == item then
			M.flush(s)
		end
	end, 500)
end

function M.remove(s)
	pending[s.key] = nil
	os.remove(path(s))
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		local items = vim.tbl_values(pending)
		for _, item in ipairs(items) do
			M.flush(item.s)
		end
	end,
})

return M
