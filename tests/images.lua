-- Run: nvim --headless -u NONE -l tests/images.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local config = require("aero.config")
config.setup({ acp = { image_previews = true } })
local images = require("aero.acp.images")
local bytes = "\137PNG\r\n\26\n\0binary\255\n"
local content = { type = "image", mimeType = "image/png", data = vim.base64.encode(bytes) }
local markdown = images.markdown(content)
local path = assert(markdown:match("^!%[image%]%(<(.*)>%)$"))
local fd = assert(vim.uv.fs_open(path, "r", 0))
assert(vim.uv.fs_read(fd, #bytes + 1, 0) == bytes, "image payload was corrupted")
vim.uv.fs_close(fd)
assert(images.markdown(content) == markdown, "identical images must reuse the cache")
vim.fn.delete(path)
assert(images.markdown(content) == markdown and vim.fn.filereadable(path) == 1, "cache was not rebuilt")
assert(images.markdown(content, true) == "[image]", "exports must not reference local cache files")
assert(images.markdown({ mimeType = "image/png", data = "!invalid" }) == "[image]")
assert(images.markdown({ mimeType = "image/svg+xml", data = content.data }) == "[image]")
local chat = {
	blocks = { { kind = "tool", status = "completed", title = "Screenshot", content = {
		{ type = "content", content = content },
	} }, { kind = "agent", text = "[image]", image = content } },
	queue = {}, s = { agent = "fixture" }, agent_title = function() return "Agent" end,
}
local renderer = require("aero.acp.render")
local transcript = table.concat(renderer.build(chat), "\n")
local _, count = transcript:gsub("!%[image%]", "")
assert(count == 2, "tool and message images must both be rendered")
assert(not transcript:find("```text", 1, true), "image links must not be fenced")
assert(not table.concat(renderer.build(chat, { export = true }), "\n"):find("![image]", 1, true))
config.options.acp.image_previews = false
assert(images.markdown(content) == "[image]")
vim.fn.delete(path)
print("image transcript tests passed")
