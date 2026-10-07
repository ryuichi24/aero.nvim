-- Worktree-scoped Markdown reports, attached to agent drafts without submitting them.
local api = vim.api
local config = require("aero.config")
local sessions = require("aero.session")
local panel = require("aero.panel")
local M = {}

local function notify(message)
	vim.notify("Aero: " .. message, vim.log.levels.WARN)
end

local canonical = require("aero.storage").canonical
local folder = require("aero.storage").folder

--- Resolve storage without creating directories. Custom roots retain worktree isolation.
function M.directory(worktree, ws)
	worktree = canonical(worktree)
	local setting = config.options.reports.directory
	if setting == "worktree" then
		return vim.fs.joinpath(worktree, ".aero", "reports")
	end
	local root = ws and ws.root or require("aero.git").main_root(worktree) or worktree
	root = canonical(root)
	if type(setting) == "function" then
		local ok, path = pcall(setting, worktree, root)
		if not ok then
			return nil, tostring(path)
		end
		if type(path) ~= "string" or path == "" then
			return nil, "reports.directory must return a directory path"
		end
		path = vim.fn.expand(path)
		return canonical(vim.startswith(path, "/") and path or vim.fs.joinpath(worktree, path))
	end
	if type(setting) ~= "string" or setting == "" then
		return nil, "reports.directory must be data, worktree, a path, or a function"
	end
	local base = setting == "data" and vim.fs.joinpath(vim.fn.stdpath("data"), "Aero", "workspaces")
		or vim.fn.expand(setting)
	if setting ~= "data" and not vim.startswith(base, "/") then
		return canonical(vim.fs.joinpath(worktree, base))
	end
	return vim.fs.joinpath(canonical(base), folder(root), folder(worktree), "reports")
end

function M.list(worktree, ws)
	local directory, err = M.directory(worktree, ws)
	if not directory then
		return {}, err
	end
	local scan, scan_err, code = vim.uv.fs_scandir(directory)
	if not scan then
		return {}, code ~= "ENOENT" and scan_err or nil
	end
	local reports = {}
	while true do
		local name, kind = vim.uv.fs_scandir_next(scan)
		if not name then
			break
		end
		if kind == "file" and name:match("%.md$") then
			table.insert(reports, { name = name, path = vim.fs.joinpath(directory, name) })
		end
	end
	table.sort(reports, function(a, b)
		return a.name < b.name
	end)
	return reports
end

--- Create a report exclusively, for either the UI or a bound MCP session.
function M.create_file(worktree, ws, name, body)
	if type(name) ~= "string" or vim.trim(name) == "" then
		return nil, "a report filename is required"
	end
	if type(body) ~= "string" then
		return nil, "report body must be a Markdown string"
	end
	name = vim.trim(name)
	if not name:match("%.md$") then
		name = name .. ".md"
	end
	if name == ".md" or name:find("[/\\%c]") then
		return nil, "use a report filename without directory separators or control characters"
	end
	local directory, err = M.directory(worktree, ws)
	if not directory then
		return nil, err
	end
	local ok, mkdir_err = pcall(vim.fn.mkdir, directory, "p")
	if not ok then
		return nil, "could not create report directory: " .. tostring(mkdir_err)
	end
	local path = vim.fs.joinpath(directory, name)
	local fd, open_err = vim.uv.fs_open(path, "wx", 420)
	if not fd then
		return nil, "could not create report: " .. tostring(open_err)
	end
	local offset = 0
	while offset < #body do
		local written, write_err = vim.uv.fs_write(fd, body:sub(offset + 1), offset)
		if not written or written == 0 then
			vim.uv.fs_close(fd)
			vim.uv.fs_unlink(path)
			return nil, "could not write report: " .. tostring(write_err)
		end
		offset = offset + written
	end
	local closed, close_err = vim.uv.fs_close(fd)
	if not closed then
		vim.uv.fs_unlink(path)
		return nil, "could not close report: " .. tostring(close_err)
	end
	return { name = name, path = path }
end

--- Ask for a name and create an empty report exclusively, preserving existing files.
function M.create(worktree, ws, callback)
	local directory, err = M.directory(worktree, ws)
	if not directory then
		notify(err)
		return
	end
	vim.ui.input({ prompt = "New report name: " }, function(name)
		if not name or vim.trim(name) == "" then
			return
		end
		local report, create_err = M.create_file(worktree, ws, name, "")
		if not report then
			notify(create_err)
			return
		end
		require("aero.dashboard").render()
		callback(report)
	end)
end

function M.rename(report, callback)
	vim.ui.input({ prompt = "Rename report: ", default = report.name }, function(name)
		if not name or vim.trim(name) == "" then
			return
		end
		name = vim.trim(name)
		if not name:match("%.md$") then
			name = name .. ".md"
		end
		if name == ".md" or name:find("[/\\%c]") then
			notify("use a report filename without directory separators or control characters")
			return
		end
		local path = vim.fs.joinpath(vim.fs.dirname(report.path), name)
		if path == report.path then
			return
		end
		if vim.uv.fs_lstat(path) then
			notify("a report with that name already exists")
			return
		end
		local buf = vim.fn.bufnr(report.path)
		local target_buf = vim.fn.bufnr(path)
		if target_buf ~= -1 then
			notify("a buffer with that report name already exists")
			return
		end
		local ok, err = vim.uv.fs_rename(report.path, path)
		if not ok then
			notify("could not rename report: " .. tostring(err))
			return
		end
		if buf ~= -1 then
			api.nvim_buf_set_name(buf, path)
		end
		callback({ name = name, path = path })
	end)
end

--- Move the saved file while retaining any open buffer and its unsaved edits.
function M.move(report, worktree, ws)
	local directory, err = M.directory(worktree, ws)
	if not directory then
		return nil, err
	end
	local path = vim.fs.joinpath(directory, report.name)
	if canonical(path) == canonical(report.path) then
		return nil, "report is already in that directory"
	end
	if vim.uv.fs_lstat(path) then
		return nil, "a report with that name already exists"
	end
	if vim.fn.bufnr(path) ~= -1 then
		return nil, "a buffer with that report name already exists"
	end
	local ok, mkdir_err = pcall(vim.fn.mkdir, directory, "p")
	if not ok then
		return nil, "could not create report directory: " .. tostring(mkdir_err)
	end
	-- Exclusive copy also supports destinations on another filesystem.
	local copied, copy_err = vim.uv.fs_copyfile(report.path, path, 1)
	if not copied then
		return nil, "could not move report: " .. tostring(copy_err)
	end
	local removed, remove_err = vim.uv.fs_unlink(report.path)
	if not removed then
		local cleaned, cleanup_err = vim.uv.fs_unlink(path)
		return nil,
			"could not remove source report: "
				.. tostring(remove_err)
				.. (not cleaned and ("; destination copy retained at " .. path .. ": " .. tostring(cleanup_err)) or "")
	end
	local buf = vim.fn.bufnr(report.path)
	if buf ~= -1 then
		api.nvim_buf_set_name(buf, path)
	end
	return { name = report.name, path = path }
end

function M.attach(s, path)
	if not vim.tbl_contains(sessions.all(), s) then
		return
	end
	if not vim.uv.fs_stat(path) then
		notify("report no longer exists: " .. path)
		return
	end
	local instruction = config.options.reports.prompt:gsub("{path}", function()
		return vim.json.encode(path)
	end)
	return require("aero.compose").append(s, instruction)
end

-- A native floating menu keeps report selection usable without a vim.ui provider.
local function select_report(choices, title, callback)
	local previous = api.nvim_get_current_win()
	vim.cmd.stopinsert()
	local buf = api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	vim.b[buf].aero_report_picker = true
	local lines, width = {}, vim.fn.strdisplaywidth(title) + 4
	for _, choice in ipairs(choices) do
		local line = "  " .. choice.name:gsub("[\r\n]", " ")
		table.insert(lines, line)
		width = math.max(width, vim.fn.strdisplaywidth(line) + 2)
	end
	width = math.max(1, math.min(width, vim.o.columns - 4))
	local height = math.max(1, math.min(#lines, vim.o.lines - 6))
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	local win = api.nvim_open_win(buf, true, {
		relative = "editor",
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
		title_pos = "center",
		width = width,
		height = height,
		row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
		col = math.max(0, math.floor((vim.o.columns - width) / 2)),
	})
	vim.wo[win].cursorline = true
	vim.wo[win].wrap = false
	local finished = false
	local function finish(choice)
		if finished then
			return
		end
		finished = true
		if api.nvim_win_is_valid(win) then
			api.nvim_win_close(win, true)
		end
		if api.nvim_win_is_valid(previous) then
			api.nvim_set_current_win(previous)
		end
		callback(choice)
	end
	for _, key in ipairs({ "<CR>", "<2-LeftMouse>" }) do
		vim.keymap.set("n", key, function()
			finish(choices[api.nvim_win_get_cursor(win)[1]])
		end, { buffer = buf, nowait = true, desc = "Aero: select report" })
	end
	for _, key in ipairs({ "<Esc>", "q", "<C-c>" }) do
		vim.keymap.set("n", key, function()
			finish(nil)
		end, { buffer = buf, nowait = true, desc = "Aero: cancel report selection" })
	end
	api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(win),
		once = true,
		callback = function()
			if not finished then
				finished = true
				callback(nil)
			end
		end,
	})
end

function M.pick(s, ws)
	local choices, err = M.list(s.worktree, ws)
	if err then
		notify(err)
		return
	end
	table.insert(choices, { name = "New +", new = true })
	select_report(choices, "Reports for " .. vim.fs.basename(s.worktree), function(report)
		if not report or not vim.tbl_contains(sessions.all(), s) then
			return
		end
		if report.new then
			M.create(s.worktree, ws, function(created)
				M.attach(s, created.path)
			end)
		else
			M.attach(s, report.path)
		end
	end)
end

function M.choose_session(worktree, preferred, ws)
	if preferred and preferred.worktree == worktree then
		return M.pick(preferred, ws)
	end
	local candidates = sessions.list(worktree)
	if #candidates == 0 then
		notify("start an agent session in this worktree before attaching a report")
	elseif #candidates == 1 then
		M.pick(candidates[1], ws)
	else
		vim.ui.select(candidates, {
			prompt = "Attach report to agent session",
			format_item = function(s)
				return s.name .. " (" .. s.agent .. ")"
			end,
		}, function(s)
			if s then
				M.pick(s, ws)
			end
		end)
	end
end

api.nvim_create_autocmd("BufWritePost", {
	group = api.nvim_create_augroup("Aero.reports", { clear = true }),
	pattern = "*.md",
	callback = function()
		require("aero.dashboard").render()
	end,
})

return M
