-- Run: nvim --headless -u NONE -l tests/mermaid_view.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
vim.o.columns, vim.o.lines = 120, 40
local api = vim.api
local calls, registry, paths = {}, {}, {}
package.loaded.image = {
	from_file = function(path, opts)
		assert(vim.fn.filereadable(path) == 1)
		if registry[opts.id] then return registry[opts.id] end
		local image = { opts = opts, original_path = path, geometry = {}, clears = 0 }
		function image:render(geometry)
			self.geometry = vim.tbl_extend("force", self.geometry, geometry or {})
		end
		function image:clear() self.clears = self.clears + 1 end
		registry[opts.id] = image
		calls[#calls + 1] = image
		paths[path] = true
		return image
	end,
}
local mermaid, viewer = require("aero.mermaid"), require("aero.mermaid_view")
local config = require("aero.config")
config.setup({ mermaid = { enabled = true, cmd = { "python3", "tests/fixtures/mermaid.py", tostring(vim.uv.hrtime()) } } })
local buf, origin = api.nvim_get_current_buf(), api.nvim_get_current_win()
vim.bo.filetype = "markdown"
local previous_key = function() end
local mouse_fallbacks = 0
local previous_mouse = function() mouse_fallbacks = mouse_fallbacks + 1; return "<LeftMouse>" end
vim.keymap.set("n", "gM", previous_key, { buffer = buf })
vim.keymap.set("n", "<LeftMouse>", previous_mouse, { buffer = buf, expr = true })
local source = { "```mermaid", "flowchart LR", "A --> B", "```", "After the diagram." }
api.nvim_buf_set_lines(buf, 0, -1, false, source)
mermaid.setup()
local function wait(fn) assert(vim.wait(5000, fn, 10), "timed out") end
local ns = api.nvim_create_namespace("Aero.mermaid")
wait(function()
	for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
		if mark[4].virt_text and mark[4].virt_text[1][1]:find("Expand diagram", 1, true) then return true end
	end
	return false
end)
-- Click exactly the control, not the diagram source or arbitrary text.
local info, position = vim.fn.getwininfo(origin)[1], vim.fn.screenpos(origin, 3, 1)
assert(not mermaid.click({ winid = 0 }))
assert(not mermaid.click({ winid = origin, screenrow = position.row, screencol = info.wincol }))
assert(mermaid.click({ winid = origin, screenrow = position.row, screencol = info.wincol + info.width - 2 }))
wait(function() return viewer.active() ~= nil end)
local first = viewer.active()
assert(api.nvim_get_current_win() == first.win and first.origin == origin)
assert(vim.bo[first.buf].filetype ~= "markdown", "viewer must not recursively scan itself")
local floating = api.nvim_win_get_config(first.win)
assert(floating.relative == "editor" and floating.width < vim.o.columns - 2)
assert(first.image.ignore_global_max_size and first.image.max_height_window_percentage == 100)
assert(first.image.geometry.height > config.options.mermaid.max_height, "viewer inherited inline height limit")
wait(function() return calls[1].clears > 0 end)
-- Fullscreen is reversible, and editor resize updates the viewer geometry.
assert(viewer.click({ winid = first.win, line = 1, column = 3 }))
wait(function() return first.fullscreen end)
assert(api.nvim_win_get_config(first.win).width > floating.width)
vim.o.columns = 100
api.nvim_exec_autocmds("VimResized", {})
wait(function() return api.nvim_win_get_config(first.win).width == 98 end)
assert(viewer.toggle_fullscreen() and not first.fullscreen)
assert(api.nvim_win_get_config(first.win).width < 98)
assert(vim.deep_equal(source, api.nvim_buf_get_lines(buf, 0, -1, false)))
assert(viewer.click({ winid = first.win, line = 1, column = first.close_columns[1] }))
wait(function() return viewer.active() == nil end)
assert(not api.nvim_win_is_valid(first.win) and not api.nvim_buf_is_valid(first.buf))
assert(first.image.clears > 0 and first.image.window == -1)
assert(api.nvim_get_current_win() == origin)
-- Keyboard opening and repeated toggling reuse the cached PNG.
api.nvim_win_set_cursor(origin, { 2, 0 })
vim.fn.maparg("gM", "n", false, true).callback()
local second = assert(viewer.active())
assert(second.path == first.path)
assert(mermaid.preview(buf, origin, 2) and viewer.active() == nil)
assert(mermaid.preview(buf, origin, 2))
local third = viewer.active()
api.nvim_win_close(third.win, true)
wait(function() return viewer.active() == nil end)
assert(third.image.clears > 0)
-- Exercise expression mappings under Neovim's textlock, with a controlled mouse position.
api.nvim_set_current_win(origin)
vim.cmd("redraw")
info, position = vim.fn.getwininfo(origin)[1], vim.fn.screenpos(origin, 3, 1)
local getmousepos = vim.fn.getmousepos
vim.fn.getmousepos = function()
	return { winid = origin, screenrow = position.row, screencol = info.wincol + info.width - 2 }
end
api.nvim_feedkeys(api.nvim_replace_termcodes("<LeftMouse>", true, false, true), "xt", false)
wait(function() return viewer.active() ~= nil end)
local clicked = viewer.active()
vim.fn.getmousepos = function() return { winid = clicked.win, line = 1, column = 3 } end
api.nvim_feedkeys(api.nvim_replace_termcodes("<LeftMouse>", true, false, true), "xt", false)
wait(function() return clicked.fullscreen end)
viewer.close()
vim.fn.getmousepos = getmousepos
-- Outside the control the existing mouse mapping still runs; disabling restores bindings.
api.nvim_set_current_win(origin)
assert(vim.fn.maparg("<LeftMouse>", "n", false, true).callback() == "<LeftMouse>")
assert(mouse_fallbacks == 1)
-- Locate the actual rendered control when the final source line wraps.
local before_calls = #calls
api.nvim_buf_set_lines(buf, 0, -1, false, {
	"```mermaid", "flowchart LR", "A --> B %% " .. string.rep("wrapped source ", 15), "```", "Following text.",
})
wait(function() return #calls > before_calls end)
vim.cmd("redraw")
local start_row = vim.fn.screenpos(origin, 3, 1).row
local end_row = vim.fn.screenpos(origin, 3, #api.nvim_buf_get_lines(buf, 2, 3, false)[1]).row
info = vim.fn.getwininfo(origin)[1]
local control_row, control_col
for row = start_row, end_row do
	local text = ""
	for col = info.wincol, info.wincol + info.width - 1 do text = text .. vim.fn.screenstring(row, col) end
	local col = text:find("Expand diagram", 1, true)
	if col then control_row, control_col = row, info.wincol + col - 1 end
end
assert(control_row, "expand control was not visible on wrapped source")
assert(mermaid.click({ winid = origin, screenrow = control_row, screencol = control_col }), "wrapped control hit test missed rendered button")
wait(function() return viewer.active() ~= nil end)
viewer.close()
assert(mermaid.preview(buf, origin, 2))
local fourth = viewer.active()
config.options.mermaid.enabled = false
mermaid.setup()
assert(viewer.active() == nil and not api.nvim_win_is_valid(fourth.win))
assert(vim.fn.maparg("gM", "n", false, true).callback == previous_key)
assert(vim.fn.maparg("<LeftMouse>", "n", false, true).callback == previous_mouse)
assert(not mermaid.preview(buf, origin, 2))
for path in pairs(paths) do vim.fn.delete(path) end
print("Mermaid viewer passed (button hit testing, floating/fullscreen, resize, keyboard, cleanup, mouse fallback, binding restoration).")
