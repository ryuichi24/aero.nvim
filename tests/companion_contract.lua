-- The same wire fixture is checked by Lua projection, Go bridge and browser parser.
vim.opt.rtp:prepend(vim.fn.getcwd())
local fixture = vim.json.decode(table.concat(vim.fn.readfile("tests/fixtures/companion-snapshot.json"), "\n"))
local projection = require("aero.acp.projection")
local source = vim.deepcopy(fixture.sessions[1].blocks)
source[1].cache, source[1].cache_src, source[1].shown = { "stale" }, "stale", 2

assert(
	vim.deep_equal(projection.blocks(source), fixture.sessions[1].blocks),
	"editor fields leaked into the wire contract"
)

local saved = projection.blocks(source, true)

assert(saved[2].answer == "interrupted" and source[2].answer == nil, "history projection mutated live permission")

source[1].text = "changed"

assert(fixture.sessions[1].blocks[1].text == "Ready to review.", "projection fixture was mutated")

local receipts = require("aero.companion.receipts").new()
local params =
	{ operation_id = "contract-operation-001", text = "review", session = "session", conversation = "conversation" }
local fingerprint = assert(receipts.check("prompt", params))
receipts.finish(params.operation_id, fingerprint, { status = "unknown" })
local _, _, prior = receipts.check("prompt", params)

assert(prior.result.status == "unknown", "in-flight receipt lost")

receipts.finish(params.operation_id, fingerprint, { status = "accepted" })
local _, _, accepted = receipts.check("prompt", params)

assert(accepted.result.status == "accepted")

params.text = "different"

assert(not receipts.check("prompt", params), "different retry payload accepted")

print("Companion wire projection and receipt contract passed.")
