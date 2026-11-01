-- Run: nvim --headless -u NONE -l tests/dashboard_worktrees.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")

local function git(...)
	local result = vim.system({ "git", "-C", dir, ... }, { text = true }):wait()

	assert(result.code == 0, result.stderr)
end

git("init", "-b", "main")
git("-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial")
require("aero").setup({ state_file = dir .. "/state.json", animation = false })
require("aero.store").data.workspaces = { { root = dir, name = "Repository", expanded = true } }
local dashboard = require("aero.dashboard")
dashboard.open()
local buf = api.nvim_get_current_buf()

local function visible(text)
	for _, line in ipairs(api.nvim_buf_get_lines(buf, 0, -1, false)) do
		if line:find(text, 1, true) then
			return true
		end
	end

	return false
end

-- The first external worktree creates the administrative directory itself.
git("worktree", "add", "-b", "external-agent", dir .. "/external")

assert(
	vim.wait(5000, function()
		return visible("external-agent")
	end),
	"external worktree did not appear without a focus change"
)

git("worktree", "remove", dir .. "/external")

assert(
	vim.wait(5000, function()
		return not visible("external-agent")
	end),
	"removed external worktree remained in the sidebar"
)

git("worktree", "add", "-b", "focus-refresh", dir .. "/focus")
api.nvim_exec_autocmds("FocusGained", {})

assert(visible("focus-refresh"), "focus refresh reused the cached worktree list")

dashboard.close()
vim.fn.delete(dir, "rf")
print("Dashboard external worktree tests passed.")
