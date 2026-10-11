-- Materialize ACP image payloads for Markdown image renderers such as image.nvim.
local M = {}
local extensions = { ["image/png"] = "png", ["image/jpeg"] = "jpg", ["image/gif"] = "gif", ["image/webp"] = "webp", ["image/avif"] = "avif" }
local paths = {}

function M.markdown(content, export)
	if export or require("aero.config").options.acp.image_previews ~= true then
		return "[image]"
	end
	local extension = extensions[content.mimeType]
	if not extension or type(content.data) ~= "string" or content.data == "" then
		return "[image]"
	end
	local key = vim.fn.sha256(content.mimeType .. ":" .. content.data)
	local path = paths[key]
	if not path or vim.fn.filereadable(path) ~= 1 then
		local ok, result = pcall(function()
			local bytes = vim.base64.decode(content.data)
			local directory = vim.fn.stdpath("cache") .. "/aero/images"
			vim.fn.mkdir(directory, "p")
			local filename = directory .. "/" .. key .. "." .. extension
			if vim.fn.filereadable(filename) ~= 1 then
				local fd = assert(vim.uv.fs_open(filename, "w", 384))
				local written = vim.uv.fs_write(fd, bytes, 0)
				vim.uv.fs_close(fd)
				if written ~= #bytes then
					vim.fn.delete(filename)
					error("could not cache image")
				end
			end
			return filename
		end)
		if not ok then
			return "[image]"
		end
		path, paths[key] = result, result
	end
	-- Angle brackets allow cache paths with spaces; encode Markdown delimiters.
	path = path:gsub("%%", "%%25"):gsub("<", "%%3C"):gsub(">", "%%3E")
	return "![image](<" .. path .. ">)"
end

return M
