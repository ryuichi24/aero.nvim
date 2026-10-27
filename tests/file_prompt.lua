-- Run: nvim --headless -u NONE -l tests/file_prompt.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local selected = { state = "ready", s = {} }
selected.buf = api.nvim_create_buf(false, true)
selected.prompt_buf = api.nvim_create_buf(false, true)
selected.chat = selected
package.loaded["aero.session_target"] = {
	resolve = function()
		return selected
	end,
}
package.loaded["aero.compose"] = {
	append = function(s, text)
		assert(s == selected)

		api.nvim_buf_set_lines(s.prompt_buf, 0, -1, false, { text, "", "Explain this file" })
		return true
	end,
}
local sent

function selected:prompt(text)
	sent = text
end

local source = api.nvim_create_buf(false, false)
api.nvim_set_current_buf(source)
local root = vim.fn.tempname()

for _, name in ipairs({ "source.lua", "source with spaces.lua" }) do
	local path = root .. "/" .. name
	api.nvim_buf_set_name(source, path)

	assert(require("aero.commands").file() == selected)

	require("aero.acp.prompt").send(selected, true)

	assert(not sent:match("^%s*/"), "file prompt was interpreted as a slash command")

	local encoded = path:find("%s") and vim.json.encode(path) or path

	assert(sent == "File: " .. encoded .. "\n\nExplain this file", "file path or prompt was lost")
end

print("file prompt: ok")
