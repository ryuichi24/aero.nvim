vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = assert(vim.env.AERO_COMPANION_TEST_DIR)
local managed = vim.env.AERO_COMPANION_TEST_MANAGED == "1"
local port = tonumber(vim.env.AERO_COMPANION_BROWSER_PORT) or 8765
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	start_insert = false,
	companion = managed and {
		port = port,
		origin = "http://localhost:" .. port,
		devices_file = assert(vim.env.AERO_COMPANION_DEVICE_STORE),
	} or {},
	agents = { fixture = { type = "acp", cmd = { "python3", vim.fn.getcwd() .. "/tests/fixtures/companion_acp.py" } } },
})
local definitions = { { path = vim.fn.getcwd(), name = "Companion test" } }
if vim.env.AERO_COMPANION_BROWSER_GROUPS == "1" then
	local aero, website = dir .. "/Aero", dir .. "/Website"
	vim.fn.mkdir(aero, "p")
	vim.fn.mkdir(website, "p")
	require("aero.store").add_workspace(aero)
	require("aero.store").add_workspace(website)
	definitions = {
		{ path = aero .. "/main", name = "Planner" },
		{ path = aero .. "/main", name = "Reviewer" },
		{ path = aero .. "/mobile-ui", name = "Mobile builder" },
		{ path = website .. "/main", name = "Writer" },
	}
end
for _, definition in ipairs(definitions) do
	vim.fn.mkdir(definition.path, "p")
	local s = assert(require("aero.session").create(definition.path, "fixture", definition.name))
	assert(require("aero.panel").show(s))
	assert(vim.wait(5000, function()
		return s.chat.state == "ready"
	end, 10))
	s.chat:info("Existing transcript: companion fixture ready")
	s.chat:changed()
end
if managed then
	vim.cmd("runtime plugin/aero.lua")
	vim.cmd("Aero companion start")
	assert(vim.wait(10000, function()
		return require("aero.companion").status().ready
	end, 10))
	local status = require("aero.companion").status()
	vim.fn.writefile(
		{ vim.json.encode({ origin = status.info.origin, code = status.info.code, pid = status.pid }) },
		dir .. "/managed-ready.json"
	)
	assert(vim.uv.fs_chmod(dir .. "/managed-ready.json", 384))
else
	local socket = require("aero.companion").start()
	vim.fn.writefile({ socket }, dir .. "/socket-path")
end
vim.wait(600000, function()
	return vim.uv.fs_stat(dir .. "/quit") ~= nil
end, 20)
vim.cmd("qa!")
