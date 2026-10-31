vim.opt.rtp:prepend(vim.fn.getcwd())
local atomic = require("aero.atomic_file")
local uv = vim.uv
local root = vim.fn.tempname()
local path = root .. "/nested/state"

local function read()
	local file = assert(io.open(path, "rb"))
	local content = file:read("*a")
	file:close()
	return content
end

local function clean()
	local names = vim.fn.readdir(vim.fs.dirname(path))

	assert(#names == 1 and names[1] == "state", "temporary file leaked")
end

for _, content in ipairs({ "", "no final newline", "with newline\n", "a\0b\r\nUTF-8: 日本語" }) do
	assert(atomic.write(path, content))
	assert(read() == content, "file bytes changed")

	clean()
end

assert(uv.fs_chmod(path, 416))
assert(atomic.write(path, "original"))
assert(uv.fs_stat(path).mode % 512 == 416, "replacement changed permissions")

local function fail(operation, replacement)
	local original = uv[operation]
	uv[operation] = replacement
	local ran, ok, err = pcall(atomic.write, path, "replacement")
	uv[operation] = original

	assert(ran, tostring(ok))
	assert(not ok and err, "failure was not reported")
	assert(read() == "original", "failed write replaced destination")

	clean()
end

fail("fs_mkstemp", function()
	return nil, "injected create failure"
end)

local write = uv.fs_write
fail("fs_write", function(fd, content, offset)
	return write(fd, content:sub(1, 2), offset)
end)

fail("fs_write", function()
	return nil, "injected write failure"
end)

local close = uv.fs_close
fail("fs_close", function(fd)
	close(fd)
	return nil, "injected close failure"
end)

fail("fs_chmod", function()
	return nil, "injected chmod failure"
end)

fail("fs_rename", function()
	return nil, "injected rename failure"
end)

-- Interleaved writers must reserve distinct temporary files.
local rename = uv.fs_rename
local nested = false
uv.fs_rename = function(source, destination)
	if not nested then
		nested = true

		assert(atomic.write(path, "inner"))
		assert(read() == "inner")
	end

	return rename(source, destination)
end
local ran, ok, err = pcall(atomic.write, path, "outer")
uv.fs_rename = rename

assert(ran and ok, tostring(err or ok))
assert(read() == "outer")

clean()
vim.fn.delete(root, "rf")
print("atomic file tests passed")
