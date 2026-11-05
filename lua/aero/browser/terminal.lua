local ffi = require("ffi")
local M = {}
ffi.cdef("int ioctl(int fd, unsigned long request, ...);")

function M.cell(tty)
	local request = jit.os == "OSX" and 0x40087468 or jit.os == "Linux" and 0x5413 or nil

	if not tty or not request then
		return nil
	end

	local fd = vim.uv.fs_open(tty, "r", 0)

	if not fd then
		return nil
	end

	local dimensions = ffi.new("unsigned short[4]")
	local result = ffi.C.ioctl(fd, request, dimensions)
	vim.uv.fs_close(fd)
	local rows, cols, width, height = dimensions[0], dimensions[1], dimensions[2], dimensions[3]

	if result ~= 0 or rows == 0 or cols == 0 or width < cols or height < rows then
		return nil
	end

	return { math.floor(width / cols), math.floor(height / rows) }
end

return M
