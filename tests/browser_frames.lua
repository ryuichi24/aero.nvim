vim.opt.rtp:prepend(vim.fn.getcwd())
local ffi = require("ffi")
local frames = require("aero.browser.frames")
local api = vim.api
ffi.cdef(
	"int uncompress(unsigned char *dest, unsigned long *destLen, const unsigned char *source, unsigned long sourceLen);"
)
local zlib = ffi.load("z")
local serial = 0

local function frame(data, width, height)
	serial = serial + 1
	local name = "/px-test-" .. vim.fn.getpid() .. "-" .. serial
	local flags = jit.os == "OSX" and (2 + 0x200 + 0x800) or (2 + 64 + 128)
	local fd = ffi.C.shm_open(name, flags, ffi.new("int", 384))

	assert(fd >= 0)
	assert(vim.uv.fs_ftruncate(fd, #data))

	local memory = ffi.C.mmap(nil, #data, 3, 1, fd, 0)

	assert(memory ~= ffi.cast("void *", -1))

	ffi.copy(memory, data, #data)
	ffi.C.munmap(memory, #data)
	ffi.C.close(fd)
	return { type = "frame", shm = name, format = "rgba", width = width, height = height, cols = 4, rows = 2 }
end

local function removed(message)
	local fd = ffi.C.shm_open(message.shm, 0)

	if fd >= 0 then
		ffi.C.close(fd)
		return false
	end

	return true
end

local output, placed, errors, flushes = {}, {}, {}, 0
api.nvim_ui_send = function(data)
	output[#output + 1] = data
end
api.nvim__redraw = function(options)
	assert(options.flush)

	flushes = flushes + 1
end
local renderer = frames.new(77, true, function(message)
	placed[#placed + 1] = message
end, function(message)
	errors[#errors + 1] = message
end)
local superseded = frame(string.rep("\0", 32), 4, 2)
local first = frame(string.rep("\255\0\0\255", 4096), 128, 32)
renderer.push(superseded)
renderer.push(first)
local empty = frame("\0", 0, 0)
renderer.push(empty)

assert(removed(empty))
assert(removed(superseded))
assert(vim.wait(2000, function()
	return #output == 1
end))
assert(removed(first))
assert(#placed == 1 and placed[1].imageId == 77)
assert(flushes == 1)
assert(output[1]:find("\027Ptmux;\027\027_Ga=T", 1, true))
assert(output[1]:find("i=77,U=1,c=4,r=2", 1, true))
assert(output[1]:sub(-5) == "\027\027\\\027\\")

-- A second frame with an unchanged grid must reach the UI without input or focus.
local bytes = {}
local seed = 12345

for index = 1, 16384 do
	seed = bit.bxor(seed, bit.lshift(seed, 13))
	seed = bit.bxor(seed, bit.rshift(seed, 17))
	seed = bit.bxor(seed, bit.lshift(seed, 5))
	bytes[index] = string.char(bit.band(seed, 255))
end

local data = table.concat(bytes)
local second = frame(data, 128, 32)
renderer.push(second)

assert(vim.wait(2000, function()
	return #output == 2
end))
assert(removed(second))
assert(#placed == 1)
assert(flushes == 2)
assert(#errors == 0, table.concat(errors, "\n"))
assert(output[2]:find("a=f,f=32,t=d,i=77,r=1,X=1,x=0,y=0,s=128,v=32", 1, true))
assert(not output[2]:find("a=T", 1, true), "Stable-size updates must not destroy image placements")
assert(not output[2]:find("a=d", 1, true))

local chunks = {}
local count = 0

for sequence in output[2]:gmatch("\027Ptmux;(.-)\027\027\\\027\\") do
	count = count + 1
	sequence = sequence:gsub("\027\027", "\027") .. "\027\\"

	assert(sequence:sub(1, 3) == "\027_G")
	assert(sequence:sub(4, 7) == "a=f,", "Every animation-frame chunk requires a=f")

	chunks[#chunks + 1] = assert(sequence:match(";([A-Za-z0-9+/=]+)\027\\$"))
end

assert(count > 1)
assert(output[2]:find("m=1;", 1, true))
assert(output[2]:find("m=0;", 1, true))

local encoded = vim.base64.decode(table.concat(chunks))
local decoded = ffi.new("unsigned char[?]", #data)
local length = ffi.new("unsigned long[1]", #data)

assert(zlib.uncompress(decoded, length, encoded, #encoded) == 0)
assert(ffi.string(decoded, tonumber(length[0])) == data)

local pending = frame(string.rep("\0", 32), 4, 2)
renderer.push(pending)
renderer.stop()

assert(removed(pending))
assert(output[3]:find("a=d,d=I,i=77", 1, true))

vim.wait(40, function()
	return false
end)

assert(#output == 3)

local invalid = frame("\0", 4, 2)
local broken = frames.new(78, false, function()
	error("A truncated frame must not be placed")
end, function(message)
	errors[#errors + 1] = message
end)
broken.push(invalid)

assert(vim.wait(2000, function()
	return #errors == 1
end))
assert(errors[1]:find("truncated", 1, true))
assert(removed(invalid))

-- A high-resolution frame above the old 16-megapixel limit is valid in shape.
-- A deliberately short backing object must fail the memory-size check instead.
local large = frame("\0", 8192, 2160)
broken.push(large)

assert(vim.wait(2000, function()
	return #errors == 2
end))
assert(errors[2]:find("truncated", 1, true))
assert(removed(large))

local malformed = frame("\0", -1, 10)
broken.push(malformed)

assert(vim.wait(2000, function()
	return #errors == 3
end))
assert(errors[3]:find("-1 x 10", 1, true))
assert(removed(malformed))

broken.stop()

local grids = {}
local resizing = frames.new(79, true, function(message)
	grids[#grids + 1] = message
end, function(message)
	error(message)
end)
local full = frame(string.rep("\0", 32), 4, 2)
resizing.push(full)

assert(vim.wait(2000, function()
	return #grids == 1
end))

local queued = frame(string.rep("\0", 32), 4, 2)
resizing.push(queued)
local before_resize = #output
resizing.resize({ width = 2, height = 1 })

assert(removed(queued))
assert(#output == before_resize + 1)
assert(output[#output]:find("a=d,d=I,i=79", 1, true))

local stale = frame(string.rep("\0", 32), 4, 2)
resizing.push(stale)

assert(removed(stale))
assert(#output == before_resize + 1)

local small = frame(string.rep("\0", 8), 2, 1)
small.cols, small.rows = 2, 1
resizing.push(small)

assert(vim.wait(2000, function()
	return #grids == 2
end))
assert(grids[2].cols == 2 and grids[2].rows == 1)
assert(output[#output]:find("s=2,v=1", 1, true))
assert(output[#output]:find("c=2,r=1", 1, true))

resizing.resize({ width = 4, height = 2 })

assert(output[#output]:find("a=d,d=I,i=79", 1, true))

resizing.push(frame(string.rep("\0", 32), 4, 2))

assert(vim.wait(2000, function()
	return #grids == 3
end))
assert(grids[3].cols == 4 and grids[3].rows == 2)

resizing.stop()
print("browser frames: shared-memory delivery, tmux chunks, no-input updates, coalescing, and cleanup passed")
vim.cmd("qa!")
