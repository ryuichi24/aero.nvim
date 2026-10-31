-- Replace complete byte strings; callers own serialization, locking, and notifications.
local M = {}
local uv = vim.uv

function M.write(path, content)
	local made, failure = pcall(vim.fn.mkdir, vim.fs.dirname(path), "p")

	if not made then
		return nil, tostring(failure)
	end

	local fd, temporary = uv.fs_mkstemp(path .. ".XXXXXX")

	if not fd then
		return nil, temporary
	end

	local written, err = uv.fs_write(fd, content, 0)
	local closed, close_err = uv.fs_close(fd)

	if written ~= #content or not closed then
		uv.fs_unlink(temporary)
		return nil, err or close_err or "incomplete file write"
	end

	local stat = uv.fs_stat(path)
	local ok

	if stat then
		ok, err = uv.fs_chmod(temporary, stat.mode % 512)

		if not ok then
			uv.fs_unlink(temporary)
			return nil, err
		end
	end

	ok, err = uv.fs_rename(temporary, path)

	if not ok then
		uv.fs_unlink(temporary)
		return nil, err
	end

	return true
end

return M
