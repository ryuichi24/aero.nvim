-- Serialize synchronous state-file transactions across Neovim instances.
-- Never run editor callbacks while waiting, and never steal an existing lock.
local M = {}

function M.with_lock(path, callback)
	local made, err = pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")

	if not made then
		return nil, tostring(err)
	end

	local lock = path .. ".lock"
	local deadline = vim.uv.hrtime() + 1000000000
	while true do
		local ok, reason, code = vim.uv.fs_mkdir(lock, 448)

		if ok then
			break
		end

		if code ~= "EEXIST" then
			return nil, "cannot acquire state lock: " .. tostring(reason)
		end

		if vim.uv.hrtime() >= deadline then
			return nil, "state lock is held: " .. lock .. " (remove only after verifying its owner is gone)"
		end

		vim.uv.sleep(10)
	end
	local owner_path = lock .. "/owner.json"
	local fd, open_err = vim.uv.fs_open(owner_path, "w", 384)

	if not fd then
		vim.uv.fs_rmdir(lock)
		return nil, "cannot record state lock owner: " .. tostring(open_err)
	end

	local owner = vim.json.encode({ pid = vim.fn.getpid(), host = vim.uv.os_gethostname() })
	local written, write_err = vim.uv.fs_write(fd, owner, 0)
	vim.uv.fs_close(fd)

	if written ~= #owner then
		vim.uv.fs_unlink(owner_path)
		vim.uv.fs_rmdir(lock)
		return nil, "cannot record state lock owner: " .. tostring(write_err)
	end

	local function pack(...)
		return { n = select("#", ...), ... }
	end

	local result = pack(xpcall(callback, debug.traceback))
	vim.uv.fs_unlink(owner_path)
	local released, release_err = vim.uv.fs_rmdir(lock)

	if not result[1] then
		return nil, tostring(result[2])
	end

	if not released then
		return nil, "cannot release state lock: " .. tostring(release_err)
	end

	return unpack(result, 2, result.n)
end

return M
