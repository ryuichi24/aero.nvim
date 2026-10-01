local M = {}

---@class Aero.Agent
---@field type? "terminal"|"acp"  terminal: run the CLI in a :terminal; acp: speak Agent Client Protocol over stdio
---@field cmd string[]|fun(session: table): string[]  command for a fresh session
---@field resume? string[]|fun(session: table): string[]  (terminal) command used to resume a previous session
---@field key? string  dashboard key that starts this agent on the worktree under the cursor
---@field env? table<string, string>

M.defaults = {
	---@type table<string, Aero.Agent>
	agents = {
		claude = { cmd = { "claude" }, resume = { "claude", "--continue" }, key = "c" },
		codex = { cmd = { "codex" }, resume = { "codex", "resume", "--last" }, key = "x" },
		["claude-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/claude-agent-acp" }, key = "C" },
		["codex-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/codex-acp" }, key = "X" },
	},
	acp = {
		-- tool call output longer than this is truncated in the chat buffer
		max_tool_lines = 20,
		-- prompt window height
		prompt_height = 8,
	},
	-- where `a` on a workspace creates new worktrees: <repo>/../<repo>.worktrees/<branch>
	worktree_path = function(ws, branch)
		local parent = vim.fs.dirname(ws.root)
		return vim.fs.joinpath(parent, vim.fs.basename(ws.root) .. ".worktrees", (branch:gsub("/", "-")))
	end,
	dashboard = {
		position = "left", -- "left" | "right" | "current"
		width = 40,
	},
	-- sessions open in a fixed column at the edge of the tab, keeping the other windows for code.
	-- set to false to open sessions in the last used window instead
	panel = {
		position = "right", -- "left" | "right"
		width = 70,
	},
	-- the per-worktree shell opened with :Aero term / `t`, below the code window
	terminal = {
		height = 12,
		cmd = nil, -- default: { vim.o.shell }
	},
	-- give each worktree its own tab, :tcd'd to the worktree; opening a session or pressing `e`
	-- switches to it. set to false to keep everything in the current tab
	worktree_tabs = true,
	-- a session with no terminal output for this long is considered idle (waiting for you)
	idle_ms = 1500,
	-- notify when a session in a hidden buffer goes from busy to idle
	notify_idle = true,
	start_insert = true,
	-- spin the icon of busy sessions (dashboard, panel winbar, transcript footer, running tools)
	animation = true,
	-- remember sessions across restarts so they can be resumed
	persist_sessions = true,
	state_file = vim.fn.stdpath("data") .. "/Aero/state.json",
	icons = {
		expanded = "▾",
		collapsed = "▸",
		busy = "◐",
		idle = "●",
		waiting = "?",
		exited = "✗",
		stopped = "○",
	},
	-- dashboard keymaps; set an entry to false to disable it
	keymaps = {
		open = "<CR>",
		expand = "l",
		collapse = "h",
		toggle = "<Tab>",
		open_vsplit = "<C-v>",
		open_split = "<C-x>",
		open_tab = "<C-t>",
		add = "a",
		add_workspace = "A",
		delete = "d",
		stop = "s",
		restart = "r",
		refresh = "R",
		cd = ".",
		edit = "e",
		terminal = "t",
		next_workspace = "]]",
		prev_workspace = "[[",
		close = "q",
		help = "g?",
	},
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
	opts = opts or {}
	local agents = opts.agents
	opts.agents = nil
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
	-- agent definitions are replaced wholesale so list-valued commands never get merged index-by-index
	for name, agent in pairs(agents or {}) do
		M.options.agents[name] = agent or nil
	end
end

return M
