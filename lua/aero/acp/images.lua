-- Materialize ACP image payloads for Markdown image renderers such as image.nvim.
local M = {}
local extensions = {
	["image/png"] = "png",
	["image/jpeg"] = "jpg",
	["image/gif"] = "gif",
	["image/webp"] = "webp",
	["image/avif"] = "avif",
}
local paths = {}

--- Remove previews whose cached positions may become stale during a transcript edit.
--- image.nvim's TextChanged and scheduled renders can run before Markdown reparsing,
--- and screenpos() rejects cached rows beyond the new end of the buffer.
function M.before_edit(buf, first)
	local image = package.loaded.image

	if type(image) ~= "table" or type(image.get_images) ~= "function" then
		return
	end

	local ok, previews = pcall(image.get_images, { buffer = buf })

	if not ok then
		return
	end

	for _, preview in ipairs(previews) do
		local row = preview.geometry and preview.geometry.y

		if not row or row >= first - 1 then
			-- A full clear removes the preview from image.nvim's render registry.
			-- Its Markdown integration recreates it at the updated position.
			preview:clear()
		end
	end
end

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

	-- image.nvim consumes the literal Tree-sitter link_destination, including
	-- angle brackets when present. Use a bare destination for ordinary paths.
	return "![image](" .. path .. ")"
end

return M
