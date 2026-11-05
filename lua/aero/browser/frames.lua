local ffi = require("ffi")
local M = {}
ffi.cdef([[
int shm_open(const char *name, int oflag, ...);
int shm_unlink(const char *name);
void *mmap(void *addr, size_t len, int prot, int flags, int fd, long long offset);
int munmap(void *addr, size_t len);
int close(int fd);
unsigned long compressBound(unsigned long sourceLen);
int compress2(unsigned char *dest, unsigned long *destLen, const unsigned char *source, unsigned long sourceLen, int level);
]])
local compressed, zlib = pcall(ffi.load, "z")

local function name(message)
	return type(message.shm) == "string" and message.shm:match("^/px%-%w[%w%-]*$") and message.shm or nil
end

local function release(message)
	if message and name(message) then
		ffi.C.shm_unlink(message.shm)
	end
end

local function pixels(message)
	assert(name(message), "Invalid browser frame shared-memory name")
	assert(message.format == "rgba", "Unsupported browser frame format")
	local width, height = message.width, message.height
	assert(
		type(width) == "number"
			and width > 0
			and width % 1 == 0
			and type(height) == "number"
			and height > 0
			and height % 1 == 0
			and width * height <= 64 * 1024 * 1024,
		string.format(
			"Invalid browser frame dimensions: %s x %s (maximum 64 megapixels)",
			tostring(width),
			tostring(height)
		)
	)
	local length = width * height * 4
	local fd = ffi.C.shm_open(message.shm, 0)
	assert(fd >= 0, "Could not open browser frame shared memory")
	local stat = vim.uv.fs_fstat(fd)

	if not stat or stat.size < length then
		ffi.C.close(fd)
		error("Browser frame shared memory is truncated")
	end

	local memory = ffi.C.mmap(nil, length, 1, 1, fd, 0)
	ffi.C.close(fd)
	assert(memory ~= ffi.cast("void *", -1), "Could not map browser frame shared memory")
	local data = ffi.string(memory, length)
	ffi.C.munmap(memory, length)
	return data
end

local function encode(data)
	if compressed then
		local capacity = zlib.compressBound(#data)
		local buffer = ffi.new("unsigned char[?]", capacity)
		local length = ffi.new("unsigned long[1]", capacity)

		if zlib.compress2(buffer, length, data, #data, 1) == 0 then
			return vim.base64.encode(ffi.string(buffer, tonumber(length[0]))), ",o=z"
		end
	end

	return vim.base64.encode(data), ""
end

local function wrap(sequence, tmux)
	return tmux and ("\027Ptmux;" .. sequence:gsub("\027", "\027\027") .. "\027\\") or sequence
end

function M.new(image, tmux, placed, failed)
	local self = { stopped = false }
	local deletion = wrap(string.format("\027_Ga=d,d=I,i=%d,q=2\027\\", image), tmux)

	function self.resize(size)
		self.expected = { width = size.width, height = size.height }
		release(self.pending)
		self.pending = nil

		if self.cols then
			vim.api.nvim_ui_send(deletion)
		end

		self.cols, self.rows, self.width, self.height = nil, nil, nil, nil
	end

	function self.push(message)
		-- Empty canvases can occur while the guest is starting or resizing.
		-- Keep the last usable frame instead of stopping the browser.
		if
			self.stopped
			or message.width == 0
			or message.height == 0
			or self.expected and (message.width ~= self.expected.width or message.height ~= self.expected.height)
		then
			release(message)
			return
		end

		release(self.pending)
		self.pending = message

		if self.scheduled then
			return
		end

		self.scheduled = true
		vim.defer_fn(function()
			self.scheduled = false
			local frame = self.pending
			self.pending = nil

			if self.stopped or not frame then
				return
			end

			local ok, err = pcall(function()
				local payload, compression = encode(pixels(frame))
				local output = {}
				local changed_grid = self.cols ~= frame.cols or self.rows ~= frame.rows
				local replace = changed_grid or self.width ~= frame.width or self.height ~= frame.height

				if self.cols and replace then
					output[#output + 1] = deletion
				end

				for offset = 1, #payload, 4096 do
					local more = offset + 4096 <= #payload and 1 or 0
					local keys

					if offset == 1 and replace then
						keys = string.format(
							"a=T,f=32,t=d,s=%d,v=%d,i=%d,U=1,c=%d,r=%d,q=2%s,m=%d",
							frame.width,
							frame.height,
							image,
							frame.cols,
							frame.rows,
							compression,
							more
						)
					elseif offset == 1 then
						-- a=T replaces the image and deletes all its placements, even
						-- at the same size. Edit the displayed base frame instead.
						keys = string.format(
							"a=f,f=32,t=d,i=%d,r=1,X=1,x=0,y=0,s=%d,v=%d,q=2%s,m=%d",
							image,
							frame.width,
							frame.height,
							compression,
							more
						)
					else
						keys = (replace and "" or "a=f,") .. "m=" .. more
					end

					output[#output + 1] =
						wrap("\027_G" .. keys .. ";" .. payload:sub(offset, offset + 4095) .. "\027\\", tmux)
				end

				-- Use the TUI's output queue instead of a competing tty writer.
				vim.api.nvim_ui_send(table.concat(output))

				if changed_grid then
					self.cols, self.rows = frame.cols, frame.rows
					placed({ imageId = image, cols = frame.cols, rows = frame.rows })
				end

				self.width, self.height = frame.width, frame.height
				vim.api.nvim__redraw({ flush = true })
			end)
			release(frame)

			if not ok then
				failed(tostring(err))
			end
		end, 16)
	end

	function self.stop()
		self.stopped = true
		release(self.pending)
		self.pending = nil
		vim.api.nvim_ui_send(deletion)
	end

	return self
end

return M
