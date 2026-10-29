-- Run: nvim --headless -u NONE -i NONE -l tests/reveal.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local reveal = require("aero.acp.reveal")
local renderer = require("aero.acp.render")
local block = { kind = "agent", text = "你好世界 streaming text" }
local tool = {
	kind = "tool",
	id = "diff",
	status = "completed",
	content = { { type = "diff", path = "example.lua", oldText = "before\n", newText = "after\n" } },
}
local chat = {
	blocks = { block, tool },
	queue = {},
	state = "ready",
	agent_title = function()
		return "Fixture"
	end,
}
local original = vim.deepcopy(chat.blocks)
reveal.track(chat, block, 0)

assert(reveal.text(block) == "")
assert(reveal.advance(chat, false))

local visible = reveal.text(block)

assert(visible ~= "" and vim.str_utfindex(visible, "utf-32") > 0, "reveal split a UTF-8 character")

-- Repeated chunks preserve the current reveal point rather than restarting it.
block.text = block.text .. " appended"
reveal.track(chat, block, #block.text - #" appended")

assert(reveal.text(block) == visible)

original[1].text = block.text
local live = table.concat(renderer.build(chat), "\n")
local exported = table.concat(renderer.build(chat, { export = true }), "\n")

assert(not live:find(block.text, 1, true), "live render ignored streaming progress")
assert(exported:find(block.text, 1, true), "export omitted unrevealed text")
assert(reveal.text(block) == visible, "export changed live reveal progress")
assert(vim.deep_equal(chat.blocks, original), "render/reveal mutated conversation records")

-- Protocol updates replace content tables; invalidate both layout and diff caches.
tool.content = { { type = "diff", path = "example.lua", oldText = "before\n", newText = "replacement\n" } }
local updated = table.concat(renderer.build(chat), "\n")

assert(updated:find("+replacement", 1, true), "diff cache retained stale output")
assert(not reveal.advance(chat, true))
assert(reveal.text(block) == block.text)

-- A new burst starts from the fully revealed prefix; chats advance independently.
local length = #block.text
block.text = block.text .. " next burst"
reveal.track(chat, block, length)
local other = { kind = "thought", text = "independent conversation" }
local other_chat = {}
reveal.track(other_chat, other, 0)
reveal.advance(chat, true)

assert(reveal.text(block) == block.text and reveal.text(other) == "")
assert(not reveal.advance(other_chat, true))
assert(not reveal.advance({}, false))
assert(block.shown == nil and tool.cache == nil and block.cache_src == nil)

print("Reveal tests passed (UTF-8, streaming bursts, isolation, export, cache invalidation).")
vim.cmd("qa!")
