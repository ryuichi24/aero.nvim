vim.opt.rtp:prepend(vim.fn.getcwd())
local ffi = require("ffi")
local terminal = require("aero.browser.terminal")
local tty
local job = vim.fn.jobstart({ "sh", "-c", "tty; cat" }, {
	pty = true,
	on_stdout = function(_, data)
		for _, line in ipairs(data) do
			tty = tty or line:match("(/dev/%S+)")
		end
	end,
})

assert(job > 0)
assert(vim.wait(2000, function()
	return tty ~= nil
end))

local fd = assert(vim.uv.fs_open(tty, "r", 0))
local request = jit.os == "OSX" and 0x80087467 or 0x5414
local dimensions = ffi.new("unsigned short[4]", { 50, 100, 2100, 2000 })

assert(ffi.C.ioctl(fd, request, dimensions) == 0)
assert(vim.deep_equal(terminal.cell(tty), { 21, 40 }))

dimensions[2], dimensions[3] = 700, 650

assert(ffi.C.ioctl(fd, request, dimensions) == 0)
assert(vim.deep_equal(terminal.cell(tty), { 7, 13 }))

dimensions[2], dimensions[3] = 0, 0

assert(ffi.C.ioctl(fd, request, dimensions) == 0)
assert(terminal.cell(tty) == nil)
assert(terminal.cell("/nonexistent/aero-terminal") == nil)

vim.uv.fs_close(fd)
vim.fn.jobstop(job)
print("browser terminal: real PTY dimensions, font resizing, and unavailable size fallback passed")
vim.cmd("qa!")
