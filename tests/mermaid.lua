-- Run: nvim --headless -u NONE -l tests/mermaid.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local mermaid = require("aero.mermaid")

local function scan(text)
	return mermaid.blocks(vim.split(text, "\n", { plain = true }))
end

assert(#scan("```mermaid\ngraph TD\nA --> B") == 0, "incomplete streamed fence rendered")

local wrapped = scan("````markdown\n```mermaid\ngraph TD\nA --> B\n```\n````")

assert(
	#wrapped == 1 and wrapped[1].row == 5 and wrapped[1].anchor_row == 3 and wrapped[1].source == "graph TD\nA --> B",
	"single wrapped diagram not detected"
)
assert(#scan("````md\n\n```mermaid\ngraph TD\nA --> B\n```\n\n````") == 1)
assert(#scan("````markdown\nExample text\n```mermaid\ngraph TD\nA --> B\n```\n````") == 0, "mixed example rendered")
assert(#scan("````markdown\n```mermaid\ngraph TD\nA --> B\n```\n```mermaid\ngraph TD\nC --> D\n```\n````") == 0)
assert(#scan("```text\n```mermaid\nA --> B\n```\n```") == 0)
assert(#scan("    ```mermaid\n    A --> B\n    ```") == 0, "indented code rendered")

local blocks = scan("  ~~~mermaid\n  graph TD\n  A --> B\n  ~~~~\n```mermaid\nsequenceDiagram\nA->>B: Hello\n```")

assert(#blocks == 2 and blocks[1].row == 3 and blocks[1].source == "graph TD\nA --> B")

local calls, cache_paths, registry = {}, {}, {}
package.loaded.image = {
	from_file = function(path, opts)
		assert(vim.fn.filereadable(path) == 1, "rendered before generation completed")

		if registry[opts.id] then
			return registry[opts.id]
		end

		local item = { path = path, opts = opts, renders = 0, clears = 0 }

		function item:render()
			self.renders = self.renders + 1
		end

		function item:clear()
			self.clears = self.clears + 1
		end

		table.insert(calls, item)
		registry[opts.id] = item
		cache_paths[path] = true
		return item
	end,
}
local config = require("aero.config")
local salt = tostring(vim.uv.hrtime())
config.setup({ mermaid = { enabled = true, cmd = { "python3", "tests/fixtures/mermaid.py", salt } } })
mermaid.setup()
local buf = api.nvim_create_buf(false, true)
api.nvim_win_set_buf(0, buf)
vim.bo[buf].filetype = "markdown"
local source = { "# Diagram", "```mermaid", "graph TD", "A --> B", "```", "After the diagram." }
api.nvim_buf_set_lines(buf, 0, -1, false, source)

local function wait(fn)
	assert(vim.wait(5000, fn, 10), "timed out")
end

wait(function()
	return #calls == 1 and calls[1].renders > 0
end)

assert(
	calls[1].opts.with_virtual_padding and calls[1].opts.y == 3,
	"padding must not be anchored to a concealable fence"
)
assert(vim.deep_equal(source, api.nvim_buf_get_lines(buf, 0, -1, false)), "preview changed Markdown source")

-- A second window uses the same cached PNG and its own window-bound image.
vim.cmd("vsplit")
wait(function()
	return #calls == 2
end)

assert(calls[1].path == calls[2].path and calls[1].opts.window ~= calls[2].opts.window)

local second = api.nvim_get_current_win()
api.nvim_win_close(second, true)
wait(function()
	return calls[2].clears > 0
end)

-- Streamed/incomplete replacements remove old images and wait for a closing fence.
api.nvim_buf_set_lines(buf, 0, -1, false, { "```mermaid", "graph LR", "C --> D" })
wait(function()
	return calls[1].clears > 0
end)

assert(#calls == 2)

api.nvim_buf_set_lines(buf, 3, 3, false, { "```" })
wait(function()
	return #calls == 3
end)

assert(calls[3].path ~= calls[1].path, "changed diagram reused stale PNG")

-- Invalid diagrams retain the source and show an error rather than a stale image.
api.nvim_buf_set_lines(buf, 0, -1, false, { "```mermaid", "INVALID", "```" })
local ns = api.nvim_create_namespace("Aero.mermaid")

local function status()
	local text = ""

	for _, mark in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
		for _, chunk in ipairs(mark[4].virt_text or {}) do
			text = text .. chunk[1]
		end
	end

	return text
end

wait(function()
	return status():find("Parse error", 1, true)
end)

assert(api.nvim_buf_get_lines(buf, 1, 2, false)[1] == "INVALID")
assert(calls[3].clears > 0)

-- Returning to a cached diagram restores a retired image.nvim registry object.
api.nvim_buf_set_lines(buf, 0, -1, false, source)
wait(function()
	return calls[1].renders > 1 and calls[1].window == api.nvim_get_current_win()
end)

-- ACP transcript output is a read-only Markdown buffer and uses the same preview.
local chat = {
	s = { agent = "fixture" },
	queue = {},
	agent_title = function()
		return "Agent"
	end,
	blocks = { { kind = "agent", text = "````markdown\n```mermaid\nsequenceDiagram\nA->>B: Hello\n```\n````" } },
}
local transcript = require("aero.acp.render").build(chat)
api.nvim_buf_set_lines(buf, 0, -1, false, transcript)
vim.bo[buf].modifiable = false
wait(function()
	return #calls == 4
end)

assert(vim.deep_equal(transcript, api.nvim_buf_get_lines(buf, 0, -1, false)))

-- Ongoing text updates must not starve a completed diagram's preview.
vim.bo[buf].modifiable = true
api.nvim_buf_set_lines(buf, 0, -1, false, { "```mermaid", "flowchart LR", "Stream --> Preview", "```", "Streaming…" })
local timer = vim.uv.new_timer()
local streamed = 0
timer:start(
	0,
	20,
	vim.schedule_wrap(function()
		streamed = streamed + 1
		api.nvim_buf_set_lines(buf, 4, 5, false, { "Streaming update " .. streamed })
	end)
)
wait(function()
	return #calls == 5
end)
timer:stop()
timer:close()

assert(streamed > 2, "streaming regression did not exercise repeated edits")

-- Missing CLI is explained inline without launching jobs.
config.options.mermaid.cmd = { "aero-missing-mermaid-cli" }
mermaid.setup()
wait(function()
	return status():find("executable not found", 1, true)
end)
config.options.mermaid.enabled = false
mermaid.setup()

assert(#api.nvim_buf_get_extmarks(buf, ns, 0, -1, {}) == 0)

api.nvim_buf_delete(buf, { force = true })

for path in pairs(cache_paths) do
	vim.fn.delete(path)
end

print("Mermaid tests passed (fences, async generation, source preservation, windows, edits, errors, disabling).")
