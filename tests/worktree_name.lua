-- Run: nvim --headless -u NONE -i NONE -l tests/worktree_name.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local repo = dir .. "/repo"

local function git(args)
	local result = vim.system(vim.list_extend({ "git" }, args), { text = true }):wait()

	assert(result.code == 0, result.stderr)

	return vim.trim(result.stdout or "")
end

git({ "init", "-b", "main", repo })
git({
	"-C",
	repo,
	"-c",
	"user.name=Test",
	"-c",
	"user.email=test@example.invalid",
	"-c",
	"commit.gpgsign=false",
	"commit",
	"--allow-empty",
	"-m",
	"initial",
})
git({ "-C", repo, "branch", "feature" })
local aero = require("aero")
aero.setup({
	state_file = dir .. "/state.json",
	animation = false,
	worktree_path = function(_, branch)
		return dir .. "/" .. branch
	end,
})
require("aero.store").add_workspace(repo)
aero.open()
local api = vim.api

for line, text in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
	if text:find("repo", 1, true) then
		api.nvim_win_set_cursor(0, { line, 0 })
		break
	end
end

local named = false
vim.ui.select = function(items, opts, cb)
	if opts.prompt:find("Add worktree", 1, true) then
		cb("Check out an existing branch", 2)
	else
		assert(vim.deep_equal(items, { "feature" }), vim.inspect(items))

		cb("feature", 1)
	end
end
vim.ui.input = function(opts, cb)
	assert(opts.prompt == "Worktree name: " and opts.default == "feature")

	named = true
	cb("review checkout")
end
vim.fn.maparg("a", "n", false, true).callback()

assert(vim.wait(5000, function()
	return vim.fn.isdirectory(dir .. "/review checkout/.git") == 1
		or vim.fn.filereadable(dir .. "/review checkout/.git") == 1
end))
assert(named)
assert(git({ "-C", dir .. "/review checkout", "branch", "--show-current" }) == "feature")
assert(vim.fn.isdirectory(dir .. "/feature") == 0)
assert(
	vim.wait(5000, function()
		for _, text in ipairs(api.nvim_buf_get_lines(0, 0, -1, false)) do
			if text:find("review checkout (feature)", 1, true) then
				return true
			end
		end

		return false
	end),
	"sidebar did not show worktree name before branch"
)

vim.fn.delete(dir, "rf")
print("worktree naming tests passed")
vim.cmd.qa({ bang = true })
