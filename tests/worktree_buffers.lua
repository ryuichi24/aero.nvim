-- Run from the repository root: nvim --headless -u NONE -l tests/worktree_buffers.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local phase = vim.env.AERO_BUFFER_PHASE
if not phase then
	local dir = vim.fn.tempname()
	for _, name in ipairs({ "a", "b", "oil" }) do
		vim.fn.mkdir(dir .. "/" .. name, "p")
	end
	dir = vim.fn.resolve(dir)
	local lines = {}
	for i = 1, 20 do
		lines[i] = "line " .. i
	end
	vim.fn.writefile(lines, dir .. "/a/alpha.lua")
	vim.fn.writefile(lines, dir .. "/b/beta.lua")
	for _, step in ipairs({ "save", "restore", "shared", "missing", "disabled" }) do
		local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", "tests/worktree_buffers.lua" }, {
			env = { AERO_BUFFER_PHASE = step, AERO_BUFFER_DIR = dir },
			text = true,
		}):wait(15000)
		assert(result.code == 0, step .. ": " .. (result.stderr or "") .. (result.stdout or ""))
	end
	vim.fn.delete(dir, "rf")
	print("Worktree buffer tests passed (restart, live edits, shared tab, Oil, missing files, disabled persistence).")
	return
end

local api = vim.api
local dir = vim.env.AERO_BUFFER_DIR
local a, b, oil_dir = dir .. "/a", dir .. "/b", dir .. "/oil"
local alpha, beta = a .. "/alpha.lua", b .. "/beta.lua"
local aero = require("aero")
aero.setup({
	state_file = dir .. "/state.json",
	animation = false,
	fullscreen_key = false,
	start_insert = false,
	persist_buffers = phase ~= "disabled",
	worktree_tabs = phase ~= "shared",
	terminal = { cmd = { "cat" } },
	agents = { pty = { cmd = { "cat" }, resume = { "cat" } } },
})
local buffers = require("aero.buffers")
local store = require("aero.store")
local oil_opens = 0
package.preload["oil"] = function()
	return {
		get_current_dir = function(buf)
			return api.nvim_buf_get_name(buf):gsub("^oil://", "")
		end,
		open = function(path, _, callback)
			oil_opens = oil_opens + 1
			local buf = api.nvim_create_buf(false, true)
			api.nvim_buf_set_name(buf, "oil://" .. path .. "/")
			vim.bo[buf].filetype = "oil"
			api.nvim_set_current_buf(buf)
			api.nvim_buf_set_lines(buf, 0, -1, false, { "folder/", "first.lua", "second.lua" })
			vim.bo[buf].modified = false
			if callback then
				vim.defer_fn(function()
					callback(nil)
				end, 10)
			end
		end,
	}
end

local function path()
	return api.nvim_buf_get_name(0)
end
local function edit(file, line, col)
	vim.cmd("keepalt hide edit " .. vim.fn.fnameescape(file))
	api.nvim_win_set_cursor(0, { line, col })
end
local function saved(worktree)
	store.load()
	return store.data.worktree_buffers[worktree]
end

if phase == "save" then
	aero.open_worktree(a)
	edit(alpha, 9, 2)
	local alpha_buf = api.nvim_get_current_buf()
	api.nvim_buf_set_lines(alpha_buf, 0, 1, false, { "unsaved alpha" })
	aero.open_worktree(b)
	edit(beta, 12, 1)
	aero.open_worktree(a)
	assert(api.nvim_get_current_buf() == alpha_buf, "live buffer was not reused")
	assert(api.nvim_buf_get_lines(0, 0, 1, false)[1] == "unsaved alpha")
	assert(api.nvim_win_get_cursor(0)[1] == 9)

	-- Sidebar, agent and shell buffers must not replace the remembered code buffer.
	local code = api.nvim_get_current_win()
	aero.open()
	local sessions = require("aero.session")
	local s = sessions.create(a, "pty")
	require("aero.panel").show(s)
	api.nvim_set_current_win(require("aero.panel").win())
	local shell = require("aero.terminal").open(a, code)
	vim.cmd.stopinsert()
	buffers.flush()
	assert(saved(a).path == alpha)
	assert(api.nvim_win_get_buf(shell) ~= alpha_buf)

	aero.open_worktree(oil_dir, function(p)
		require("oil").open(p)
	end)
	api.nvim_win_set_cursor(0, { 3, 0 })
	aero.open_worktree(a)
	assert(api.nvim_get_current_buf() == alpha_buf)
	assert(oil_opens == 1)
	-- Leave with writes pending: normal shutdown must flush the latest cursor and Oil view.
	return
end

if phase == "restore" then
	aero.open_worktree(a)
	assert(path() == alpha, "file was not restored across restart")
	assert(vim.deep_equal(api.nvim_win_get_cursor(0), { 9, 2 }))
	assert(api.nvim_buf_get_lines(0, 0, 1, false)[1] == "line 1", "unsaved text was incorrectly persisted")
	aero.open_worktree(b)
	assert(path() == beta and api.nvim_win_get_cursor(0)[1] == 12)
	vim.cmd.tabclose()
	aero.open_worktree(b)
	assert(path() == beta, "closing a tab lost the last buffer")
	aero.open_worktree(oil_dir)
	assert(vim.bo.filetype == "oil" and oil_opens == 1)
	assert(vim.wait(1000, function()
		return api.nvim_win_get_cursor(0)[1] == 3
	end, 10))
	-- Unrelated state updates must preserve remembered buffers, and vice versa.
	local session_name = store.add_session(b, "pty")
	aero.open_worktree(b)
	api.nvim_win_set_cursor(0, { 11, 1 })
	buffers.remember()
	buffers.flush()
	assert(store.find_session(b, session_name))
	assert(saved(a).path == alpha and saved(oil_dir).kind == "oil")
	return
end

if phase == "shared" then
	vim.o.hidden = false
	local tabs = #api.nvim_list_tabpages()
	aero.open_worktree(a)
	assert(path() == alpha)
	local original = api.nvim_get_current_buf()
	api.nvim_buf_set_lines(0, 0, 1, false, { "shared-tab unsaved edit" })
	aero.open_worktree(b)
	assert(path() == beta)
	aero.open_worktree(a)
	assert(api.nvim_get_current_buf() == original)
	assert(api.nvim_buf_get_lines(0, 0, 1, false)[1] == "shared-tab unsaved edit")
	assert(#api.nvim_list_tabpages() == tabs, "shared-tab mode opened another tab")
	return
end

if phase == "missing" then
	vim.fn.delete(alpha)
	aero.open_worktree(a)
	assert(path():gsub("/$", "") == a, "missing file did not fall back to the directory")
	aero.open_worktree(b)
	assert(path() == beta)
	buffers.forget(b)
	assert(saved(b) == nil)
	return
end

if phase == "disabled" then
	aero.open_worktree(oil_dir)
	assert(vim.bo.filetype ~= "oil" and oil_opens == 0, "disabled persistence restored an old buffer")
	edit(beta, 2, 0)
	buffers.remember()
	buffers.flush()
	assert(store.data.worktree_buffers[oil_dir] == nil)
end
