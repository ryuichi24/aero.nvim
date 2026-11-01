vim.opt.rtp:prepend(vim.fn.getcwd())

local config = require("aero.config")
local schema = require("aero.config_schema")
local original = vim.deepcopy(config.options)

config.setup(config.defaults)

assert(vim.deep_equal(config.options, original), "public defaults must compile to runtime defaults")
assert(config.defaults.sessions.default_agent == "opencode-acp")
assert(config.defaults.ui.dashboard.keymaps.open == "<CR>")
assert(config.defaults.chat.prompt.height == 25)
assert(config.defaults.acp == nil and config.defaults.state_file == nil)
assert(config.defaults.mcp.executable == false)
assert(config.defaults.knowledge.mcp_executable == nil and config.defaults.knowledge.executable == nil)
assert(config.defaults.reading.agent.mcp_executable == nil and config.defaults.reading.agent.executable == nil)
assert(config.defaults.tasks.agent.mcp_executable == nil and config.defaults.tasks.agent.executable == nil)

local opts = {
	sessions = { default_agent = "custom", start_insert = false, prompt_name = false },
	storage = { sessions = false, buffers = false, state_file = "/tmp/aero-config-test.json" },
	worktrees = {
		tabs = false,
		path = function()
			return "/tmp/worktree"
		end,
	},
	ui = { panel = false, resize = false, dashboard = { width = 52, keymaps = { open = "go" } } },
	chat = {
		permissions = { auto_yes = true },
		transcript = { collapsed = { tools = false }, line_numbers = { show = true } },
		prompt = { height = 10, tab_completion = false, line_numbers = { relative = true } },
		todos = { enabled = false, timeout = 0 },
	},
	agents = { custom = { cmd = { "custom" } }, codex = false, opencode = { cmd = { "other" } } },
	tasks = { states = { "new" }, terminal_states = {}, agent = { adapters = { "custom" } } },
	knowledge = { embedding_command = { "embed" }, extractors = { { extensions = { ".x" }, command = { "x" } } } },
	mermaid = { cmd = { "custom-mmdc" } },
}
local before = vim.deepcopy(opts)
config.setup(opts)

assert(vim.deep_equal(opts, before), "setup must not mutate caller-owned configuration")
assert(config.options.default_agent == "custom" and not config.options.start_insert)
assert(not config.options.prompt_session_name and not config.options.persist_sessions)
assert(not config.options.persist_buffers and config.options.state_file == opts.storage.state_file)
assert(not config.options.worktree_tabs and config.options.worktree_path() == "/tmp/worktree")
assert(config.options.panel == false and config.options.resize == false)
assert(config.options.dashboard.width == 52 and config.options.dashboard.position == "left")
assert(config.options.keymaps.open == "go" and config.options.keymaps.close == "q")
assert(config.options.acp.auto_yes and not config.options.acp.collapsed.tools)
assert(config.options.acp.collapsed.thinking and config.options.acp.line_numbers.transcript.show)
assert(config.options.acp.line_numbers.prompt.relative and not config.options.acp.line_numbers.prompt.show)
assert(config.options.acp.prompt_height == 10 and not config.options.acp.tab_completion)
assert(not config.options.acp.todo_notifications and config.options.acp.todo_notification_timeout == 0)
assert(config.options.agents.codex == nil and config.options.agents.opencode.resume == nil)
assert(vim.deep_equal(config.options.tasks.states, { "new" }))
assert(vim.tbl_isempty(config.options.tasks.terminal_states))
assert(vim.deep_equal(config.options.tasks.agent.adapters, { "custom" }), "list override retained default adapters")

config.options.agents.custom.cmd[1] = "mutated"
config.options.knowledge.extractors[1].command[1] = "mutated"

assert(vim.deep_equal(opts, before), "runtime mutation must not affect caller-owned lists")

config.setup({ default_agent = "legacy", sessions = { default_agent = "new" }, context = { home = "/legacy" } })

assert(config.options.default_agent == "new", "grouped setting must win over legacy spelling")
assert(config.options.reference_finder.home == "/legacy")

local mcp_opts = {
	mcp = { executable = "/custom/aero-mcp" },
	reading = { agent = { enabled = true } },
	tasks = { agent = { enabled = true } },
	companion = { executable = "/custom/aero-companion" },
}
local mcp_before = vim.deepcopy(mcp_opts)
config.setup(mcp_opts)

assert(config.options.mcp.executable == "/custom/aero-mcp")
assert(config.options.companion.executable == "/custom/aero-companion")
assert(vim.deep_equal(mcp_opts, mcp_before), "MCP setting normalization must not mutate caller-owned tables")
assert(config.options.knowledge.mcp_executable == nil and config.options.reading.agent.mcp_executable == nil)
assert(config.options.tasks.agent.mcp_executable == nil)

-- Removed feature settings must not silently select an unrelated binary.
for _, field in ipairs({ "executable", "mcp_executable" }) do
	for _, feature in ipairs({ "knowledge", "reading", "tasks" }) do
		local options = { [field] = "/legacy/aero-mcp" }
		local invalid = { mcp = { executable = "/custom/aero-mcp" } }
		invalid[feature] = feature == "knowledge" and options or { agent = options }
		local previous = config.options
		local ok, err = pcall(config.setup, invalid)

		assert(not ok and tostring(err):find("was replaced by mcp.executable", 1, true))
		assert(config.options == previous)
	end
end

config.setup({ mcp = { executable = false } })

assert(config.options.mcp.executable == false)

local previous = config.options
local ok, err = pcall(config.setup, { chat = { prompt = { heigth = 2 } } })

assert(not ok and tostring(err):find("chat.prompt.heigth", 1, true))
assert(config.options == previous, "invalid configuration must not replace the last valid configuration")

for _, invalid in ipairs({
	{ sessions = false },
	{ ui = { unknown = true } },
	{ chat = { unknown = {} } },
	{ mcp = false },
	{ mcp = { executable = true } },
	{ mcp = { executable = {} } },
	{ mcp = { unknown = true } },
}) do
	assert(not pcall(config.setup, invalid))
end

config.setup()

assert(vim.deep_equal(config.options, original), "repeated setup must reset to pristine defaults")
assert(vim.deep_equal(schema.runtime(config.defaults), config.options))

print("config: OK")
