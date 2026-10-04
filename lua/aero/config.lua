local M = {}

---@class Aero.Agent
---@field type? "terminal"|"acp"  terminal: run the CLI in a :terminal; acp: speak Agent Client Protocol over stdio
---@field cmd string[]|fun(session: table): string[]  command for a fresh session
---@field resume? string[]|fun(session: table): string[]  (terminal) command used to resume a previous session
---@field key? string  dashboard key that starts this agent on the worktree under the cursor
---@field env? table<string, string>

M.defaults = {
	-- lifecycle event name -> function or list of functions
	events = {},
	---@type table<string, Aero.Agent>
	agents = {
		claude = { cmd = { "claude" }, resume = { "claude", "--continue" }, key = "c" },
		codex = { cmd = { "codex" }, resume = { "codex", "resume", "--last" }, key = "x" },
		opencode = { cmd = { "opencode" }, resume = { "opencode", "--continue" }, key = "o" },
		["claude-agent-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/claude-agent-acp" }, key = "C" },
		["codex-acp"] = { type = "acp", cmd = { "npx", "-y", "@agentclientprotocol/codex-acp" }, key = "X" },
		["opencode-acp"] = { type = "acp", cmd = { "opencode", "acp" }, key = "O" },
	},
	acp = {
		-- tool call output longer than this is truncated in the chat buffer
		max_tool_lines = 20,
		-- prompt window height
		prompt_height = 25,
		decorations = true, -- native transcript cards, colors, and visual borders
		show_usage = true, -- agent-reported tokens, context usage, and cumulative fees
		-- resize_keys may override the shared shortcuts for prompt buffers
	},
	reports = {
		-- "data": scoped folders in stdpath("data")/Aero/workspaces;
		-- "worktree": <worktree>/.aero/reports; or a custom storage root.
		-- A function(worktree, workspace_root) may return an exact directory.
		directory = "data",
		-- Text appended to agent drafts; {path} becomes the JSON-quoted absolute report path.
		prompt = "Report file: {path}\nRead this Markdown report for context and write or update the report at this path with your findings.",
	},
	tasks = {
		directory = "data", -- workspace scoped; "worktree" means the main checkout
		states = { "backlog", "todo", "in progress", "review", "test", "done" },
		terminal_states = { "done" }, -- overdue excludes these states
		estimate_unit = "points",
		column_width = 32, -- minimum width; hidden states remain editable through [s / ]s
		yq = vim.env.AERO_TASKS_YQ or "yq", -- Mike Farah's Go-based yq v4
		agent = {
			enabled = false,
			executable = false,
			adapters = { "opencode-acp", "claude-agent-acp", "codex-acp" },
			prompt = "Read the ticket through Aero's task tools and implement its requirements. Record progress and verification results with aero_update_ticket_body. Discover current board states before explicitly moving the ticket with aero_move_ticket. Do not write the task documents directly.",
		},
		keymaps = {
			open = "<CR>",
			source = "e",
			new = "ga",
			move = "m",
			work = "gw",
			rename = "N",
			remove = "gd",
			delete = "gD",
			metadata = "gi",
			states = "gs",
			refresh = "R",
			previous = "[s",
			next = "]s",
			up = false,
			down = false,
			earlier = "gK",
			later = "gJ",
			recover = "go",
			archive = "gA",
			close = "q",
			help = "g?",
		},
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
	layout = {
		min_code_width = 20, -- reserve a usable editor between dashboard and agent panel
	},
	-- sessions open in a fixed column at the edge of the tab, keeping the other windows for code.
	-- set to false to open sessions in the last used window instead
	panel = {
		position = "right", -- "left" | "right"
		width = 80,
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
	-- normal-mode key in every pane, including code; false disables the mapping
	fullscreen_key = "gF",
	-- visual-mode quote action in code and agent logs; false disables the mapping
	quote_key = "<leader>aq",
	-- normal-mode repeat resizing in every Aero pane; false disables the shortcuts
	resize = {
		prefix = "<C-w>",
		keys = { grow = "k", shrink = "j", narrow = "h", widen = "l" },
	},
	-- remember sessions across restarts so they can be resumed
	persist_sessions = true,
	-- ask for a name when creating a session with `a` or an agent shortcut
	prompt_session_name = true,
	input = {
		adapter = "auto", -- "auto" | "dressing" | "snacks" | "vim_ui" | function(opts, callback)
		select_default = true, -- select session names in supported input UIs
	},
	-- remember the last code file/directory in each worktree across restarts
	persist_buffers = true,
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
		rename = "N",
		refresh = "R",
		pull = "P",
		cd = ".",
		edit = "e",
		open_board_markdown = "I", -- open the selected board's raw Markdown file
		edit_enter = "<C-CR>", -- open the selected worktree in the code pane
		edit_mouse = "<C-LeftMouse>", -- open the clicked worktree in the code pane
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
	for _, field in ipairs({ "states", "terminal_states" }) do
		if opts.tasks and opts.tasks[field] ~= nil then
			M.options.tasks[field] = vim.deepcopy(opts.tasks[field])
		end
	end
	-- agent definitions are replaced wholesale so list-valued commands never get merged index-by-index
	for name, agent in pairs(agents or {}) do
		M.options.agents[name] = agent or nil
	end
end

return M
