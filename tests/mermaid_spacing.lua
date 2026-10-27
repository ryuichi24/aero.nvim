-- Integration test: requires image.nvim and ImageMagick, but no terminal or mmdc.
-- AERO_IMAGE_NVIM=/path/to/image.nvim nvim --headless -u NONE -l tests/mermaid_spacing.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local plugin = vim.env.AERO_IMAGE_NVIM or (vim.fn.stdpath("data") .. "/site/pack/core/opt/image.nvim")

assert(vim.fn.isdirectory(plugin) == 1, "set AERO_IMAGE_NVIM to your image.nvim checkout")

vim.opt.rtp:append(plugin)
local api = vim.api
local draws, expanded_draws = 0, {}
package.loaded["image/backends/kitty"] = {
	features = { crop = true },
	setup = function() end,
	clear = function() end,
	render = function(image, _, _, width, height)
		draws = draws + 1

		if image.namespace == "aero-mermaid-view" then
			expanded_draws[#expanded_draws + 1] = { width = width, height = height }
		end
	end,
}
require("image/utils/term").get_size = function()
	return { screen_cols = 80, screen_rows = 24, cell_width = 10, cell_height = 20, screen_x = 800, screen_y = 480 }
end
local image_api = require("image")
image_api.setup({
	processor = "magick_cli",
	integrations = {
		markdown = { enabled = false },
		asciidoc = { enabled = false },
		typst = { enabled = false },
		neorg = { enabled = false },
		syslang = { enabled = false },
	},
})
require("aero.config").setup({
	mermaid = {
		enabled = true,
		cmd = { "python3", "tests/fixtures/mermaid.py", tostring(vim.uv.hrtime()) },
		max_width = 10,
		max_height = 4,
	},
})
local mermaid = require("aero.mermaid")
mermaid.setup()
vim.bo.filetype = "markdown"
vim.wo.conceallevel = 3
vim.wo.concealcursor = "nvic"
vim.wo.wrap = true
local buf, win = api.nvim_get_current_buf(), api.nvim_get_current_win()
local hidden = api.nvim_create_namespace("Test.markdown.concealed-fences")
local paths = {}

local function check(source)
	api.nvim_buf_clear_namespace(buf, hidden, 0, -1)
	api.nvim_buf_set_lines(
		buf,
		0,
		-1,
		false,
		{ "```mermaid", "flowchart LR", source, "```", "Following paragraph.", "Next paragraph." }
	)

	-- render-markdown uses conceal_lines on delimiters when previewing code blocks.
	api.nvim_buf_set_extmark(buf, hidden, 0, 0, { conceal_lines = "" })
	api.nvim_buf_set_extmark(buf, hidden, 3, 0, { conceal_lines = "" })
	local before = draws

	assert(
		vim.wait(5000, function()
			return draws > before
		end, 10),
		"image never reached backend"
	)

	local image

	for _, candidate in ipairs(image_api.get_images({ namespace = "aero-mermaid", buffer = buf })) do
		if candidate.window == win then
			image = candidate
		end
	end

	assert(image and image.geometry.y == 2, "image anchored to concealed fence")

	paths[image.original_path] = true
	vim.cmd("redraw")
	local after = vim.fn.screenpos(win, 5, 1).row - 1

	assert(after >= image.rendered_geometry.y + image.rendered_geometry.height, "image overlaps following paragraph")

	local last = vim.fn.screenpos(win, 3, #source).row - 1

	assert(image.rendered_geometry.y > last, "image overlaps wrapped source line")
	assert(api.nvim_buf_get_lines(buf, 4, 5, false)[1] == "Following paragraph.")
end

check("A --> B")

check("A --> B %% " .. string.rep("long diagram source ", 10))

-- Expanded rendering uses the real image.nvim transform pipeline, not inline caps.
assert(mermaid.preview(buf, win, 2))
assert(vim.wait(5000, function()
	return #expanded_draws > 0
end, 10))

local floating = expanded_draws[#expanded_draws]

assert(floating.width > 10 and floating.height > 4, "expanded image retained inline size limits")

local viewer = require("aero.mermaid_view")
local before = #expanded_draws
viewer.toggle_fullscreen()

assert(vim.wait(5000, function()
	return #expanded_draws > before
end, 10))

local fullscreen = expanded_draws[#expanded_draws]

assert(
	fullscreen.width > floating.width and fullscreen.height > floating.height,
	"fullscreen did not enlarge the real image"
)

viewer.close()
require("aero.config").options.mermaid.enabled = false
mermaid.setup()

for path in pairs(paths) do
	vim.fn.delete(path)
end

print(
	"Mermaid integration passed (concealed fences, wrapped source, real image.nvim padding, floating/fullscreen scaling)."
)
