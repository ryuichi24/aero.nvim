-- Run: nvim --headless -u NONE -l tests/mermaid_queue.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local mermaid = require("aero.mermaid")
local config = require("aero.config")
local ns = api.nvim_create_namespace("Aero.mermaid")
local paths, images = {}, {}
package.loaded.image = {
	from_file = function(path, opts)
		paths[path] = true
		local image = { window = opts.window, buffer = opts.buffer }

		function image:render()
			images[opts.id] = self
		end

		function image:clear()
			images[opts.id] = nil
		end

		return image
	end,
}
local original_system = vim.system
local active, peak, launched = 0, 0, 0
vim.system = function(command, opts, callback)
	for index, argument in ipairs(command) do
		if argument == "-o" then
			paths[command[index + 1]] = true
		end
	end

	active, launched = active + 1, launched + 1
	peak = math.max(peak, active)
	return original_system(command, opts, function(result)
		active = active - 1
		callback(result)
	end)
end

local function wait(fn)
	assert(vim.wait(15000, fn, 10), "timed out")
end

local function progress()
	local lines = {}

	for _, mark in ipairs(api.nvim_buf_get_extmarks(0, ns, 0, -1, { details = true })) do
		for _, line in ipairs(mark[4].virt_lines or {}) do
			for _, chunk in ipairs(line) do
				table.insert(lines, chunk[1])
			end
		end
	end

	return table.concat(lines, "\n")
end

local buf = api.nvim_get_current_buf()
vim.o.lines = 100
local source = {}

for index = 1, 10 do
	vim.list_extend(
		source,
		{ "```mermaid", "flowchart LR", ("A%d --> B%d"):format(index, index), "```", "After diagram " .. index }
	)
end

api.nvim_buf_set_lines(buf, 0, -1, false, source)
vim.bo.filetype = "markdown"
vim.cmd("redraw")
config.setup({
	mermaid = {
		enabled = true,
		concurrency = 4,
		prefetch = 0,
		max_height = 100,
		cmd = { "python3", "tests/fixtures/mermaid.py", tostring(vim.uv.hrtime()), "--delay", "0.6" },
	},
})
local start = vim.uv.hrtime()
mermaid.setup()
wait(function()
	return progress():find("Queued for PNG", 1, true)
end)
local initial = progress()

assert(initial:find("Rendering PNG", 1, true) and initial:find("position", 1, true))
assert(initial:find("Mermaid 10/10", 1, true), "missing per-diagram identity")

wait(function()
	return progress() ~= initial
end)

assert(launched == 4, "progress animation launched extra jobs")

wait(function()
	return vim.tbl_count(images) == 10
end)
local elapsed = (vim.uv.hrtime() - start) / 1e9

assert(peak == 4 and launched == 10, "worker pool did not respect concurrency")
assert(progress() == "", "loading indicators survived completion")
assert(vim.deep_equal(source, api.nvim_buf_get_lines(buf, 0, -1, false)), "progress changed source")

-- Reinitialization must use the on-disk cache without new CLI invocations.
mermaid.setup()
wait(function()
	return vim.tbl_count(images) == 10
end)

assert(launched == 10, "cached diagrams relaunched CLI")

-- A short viewport should warm exactly the configured number of next diagrams.
config.options.mermaid.cmd = { "python3", "tests/fixtures/mermaid.py", tostring(vim.uv.hrtime()), "--delay", "0.6" }
config.options.mermaid.max_height = 1
config.options.mermaid.prefetch = 2
config.options.mermaid.concurrency = 1
api.nvim_win_set_height(0, 5)
vim.o.lines = 7
api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("normal! zt")
vim.cmd("redraw")
local visible_end = vim.fn.getwininfo(api.nvim_get_current_win())[1].botline + 1
local visible = 0

for _, block in ipairs(mermaid.blocks(source)) do
	if block.row + 1 <= visible_end then
		visible = visible + 1
	end
end

local before = launched
peak = 0
mermaid.setup()
wait(function()
	return launched == before + visible + 2 and active == 0
end)

assert(peak == 1, "configured concurrency ignored")

-- Delete source during animation; stale progress must not write past the buffer.
config.options.mermaid.cmd = { "python3", "tests/fixtures/mermaid.py", tostring(vim.uv.hrtime()), "--delay", "0.6" }
mermaid.setup()
wait(function()
	return progress() ~= ""
end)
api.nvim_buf_set_lines(buf, 0, -1, false, { "No diagrams" })

assert(vim.wait(400, function()
	return progress() == ""
end, 10))

config.options.mermaid.enabled = false
mermaid.setup()
vim.system = original_system

for path in pairs(paths) do
	vim.fn.delete(path)
end

print(
	("Mermaid queue passed (10 diagrams in %.2fs, four workers, progress, cache, prefetch, edits, cleanup)."):format(
		elapsed
	)
)
