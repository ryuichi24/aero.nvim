-- Run from the repository root: python3 tests/run.py --unit session_integrations
vim.opt.rtp:prepend(vim.fn.getcwd())
local integrations = require("aero.session.integrations")
local session = { task_transport = { credential = "fixture" } }
local calls, fail = {}, nil
local modules = { "aero.tasks.agent", "aero.reading_agent", "aero.browser.agent", "aero.knowledge.agent" }

for _, name in ipairs(modules) do
	package.preload[name] = function()
		error("skipped session preparation must not load integrations")
	end
end

assert(integrations.prepare(session, { type = "terminal" }))
assert(integrations.prepare(session, { type = "acp" }, { history_only = true }))

for index, name in ipairs(modules) do
	local function attach(value)
		assert(value == session)

		table.insert(calls, index)

		if fail == index then
			return nil, index == 1 and { message = "unavailable" } or "unavailable"
		end

		return true
	end

	package.loaded[name] = {
		restore = attach,
		attach = attach,
		detach = function(value)
			assert(value == session)

			table.insert(calls, index)
		end,
	}
end

assert(integrations.prepare(session, { type = "acp" }))
assert(vim.deep_equal(calls, { 1, 2, 3, 4 }))

calls = {}

assert(integrations.prepare(session, { type = "acp" }, { restore_tasks = false }))
assert(vim.deep_equal(calls, { 2, 3, 4 }))

local errors = {
	"cannot reconnect task tools: unavailable",
	"cannot attach reading tools: unavailable",
	"cannot attach browser tools: unavailable",
	"cannot attach knowledge tools: unavailable",
}

for index, message in ipairs(errors) do
	calls, fail = {}, index
	local ok, err = integrations.prepare(session, { type = "acp" })

	assert(not ok and err == message)
	assert(#calls == index, "a failed attachment must stop the pipeline without detaching earlier tools")
end

package.loaded["aero.tasks.bridge"] = {
	unbind = function(credential)
		assert(credential == "fixture")

		table.insert(calls, 1)
	end,
}
calls = {}
integrations.detach(session)

assert(vim.deep_equal(calls, { 1, 2, 3, 4 }))

session.task_transport, calls = nil, {}
integrations.detach(session)

assert(vim.deep_equal(calls, { 2, 3, 4 }))

print("Session integration lifecycle tests passed.")
