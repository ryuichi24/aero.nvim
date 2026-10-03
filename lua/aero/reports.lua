-- Worktree-scoped Markdown reports, attached to agent drafts without submitting them.
local api = vim.api
local config = require("aero.config")
local sessions = require("aero.session")
local panel = require("aero.panel")
local M = {}

local function notify(message)
	vim.notify("Aero: " .. message, vim.log.levels.WARN)
end

local function canonical(path)
	return vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ":p")))
end

local function folder(path)
	local name = vim.fs.basename(path):gsub("[^%w._-]", "-")
	return name .. "-" .. vim.fn.sha256(path):sub(1, 8)
end

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
		name = vim.trim(name)
		if not name:match("%.md$") then
			name = name .. ".md"
		end
		if name == ".md" or name:find("[/\\%c]") then
			notify("use a report filename without directory separators or control characters")
			return
		end
		local ok, mkdir_err = pcall(vim.fn.mkdir, directory, "p")
		if not ok then
			notify("could not create report directory: " .. tostring(mkdir_err))
			return
		end
		local path = vim.fs.joinpath(directory, name)
		local fd, open_err = vim.uv.fs_open(path, "wx", 420)
		if not fd then
			notify("could not create report: " .. tostring(open_err))
			return
		end
		vim.uv.fs_close(fd)
		require("aero.dashboard").render()
		callback({ name = name, path = path })
	end)
end

function M.attach(s, path)
	if not vim.tbl_contains(sessions.all(), s) then
		return
	end
	if not vim.uv.fs_stat(path) then
		notify("report no longer exists: " .. path)
		return
	end
	local win
	if panel.enabled() then
		win = panel.show(s)
	else
		for _, candidate in ipairs(api.nvim_tabpage_list_wins(0)) do
			if api.nvim_win_get_buf(candidate) == s.buf then
				win = candidate
				break
			end
		end
		win = win or api.nvim_open_win(api.nvim_create_buf(false, true), false, { split = "right" })
		win = sessions.show(s, win, false)
	end
	if not win then
		return
	end
	local instruction = config.options.reports.prompt:gsub("{path}", function()
		return vim.json.encode(path)
	end)
	if s.chat then
		local buf = s.chat:get_prompt_buf()
		local draft = api.nvim_buf_get_lines(buf, 0, -1, false)
		if #draft == 1 and draft[1] == "" then
			draft = {}
		elseif draft[#draft] ~= "" then
			table.insert(draft, "")
		end
		vim.list_extend(draft, vim.split(instruction, "\n", { plain = true }))
		table.insert(draft, "")
		api.nvim_buf_set_lines(buf, 0, -1, false, draft)
		s.chat:compose()
		api.nvim_win_set_cursor(0, { #draft, 0 })
		if not config.options.start_insert then
			vim.cmd.stopinsert()
		end
	elseif s.job then
		api.nvim_set_current_win(win)
		vim.fn.chansend(s.job, "\027[200~" .. instruction .. "\n\027[201~")
		if config.options.start_insert then
			vim.cmd.startinsert()
		end
	end
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
