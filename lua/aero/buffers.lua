-- The last code buffer per worktree. Live buffers are reused; portable descriptors are saved.
local api = vim.api
local config = require("aero.config")
local store = require("aero.store")
local M = {}
local live, pending = {}, {}
local scheduled, restoring, state_file = false, false, nil

local function key(path)
	return vim.fs.normalize(vim.fn.resolve(path))
end

local function usable(win)
	if not api.nvim_win_is_valid(win) or api.nvim_win_get_config(win).relative ~= "" then
		return false
	end
	local buf = api.nvim_win_get_buf(win)
	local b, bo = vim.b[buf], vim.bo[buf]
	if b.aero_session or b.aero_chat_key or b.aero_term or bo.filetype == "Aero" then
		return false
	end
	return bo.buftype == "" or bo.filetype == "oil" or bo.filetype == "netrw"
end

function M.code_win(tab)
	tab = tab or api.nvim_get_current_tabpage()
	local current = api.nvim_get_current_win()
	if api.nvim_win_get_tabpage(current) == tab and usable(current) then
		return current
	end
	local last = vim.t[tab].aero_code_win
	if last and usable(last) and api.nvim_win_get_tabpage(last) == tab then
		return last
	end
	for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
		if usable(win) then
			return win
		end
	end
end

local function describe(buf, win)
	local path = api.nvim_buf_get_name(buf)
	local kind
	if vim.bo[buf].filetype == "oil" then
		local ok, oil = pcall(require, "oil")
		if ok and oil.get_current_dir then
			local success, dir = pcall(oil.get_current_dir, buf)
			if success and dir then
				path = dir
			end
		end
		path = path:gsub("^oil://", "")
		if path == "" or vim.fn.isdirectory(path) ~= 1 then
			return nil
		end
		kind = "oil"
	elseif path == "" or path:match("^%a[%w+.-]*://") then
		return nil
	else
		kind = vim.fn.isdirectory(path) == 1 and "directory" or "file"
	end
	return { kind = kind, path = vim.fs.normalize(path), cursor = api.nvim_win_get_cursor(win) }
end

function M.flush()
	scheduled = false
	local changes = pending
	pending = {}
	if config.options.persist_buffers and next(changes) then
		store.set_worktree_buffers(changes)
	end
end

function M.remember(win)
	if restoring then
		return false
	end
	win = win or M.code_win()
	if not win or not usable(win) then
		return false
	end
	local tab = api.nvim_win_get_tabpage(win)
	local worktree = vim.t[tab].aero_worktree
	if not worktree then
		return false
	end
	local buf = api.nvim_win_get_buf(win)
	local data = describe(buf, win)
	-- A fresh empty startup buffer must not replace the saved file. Unsaved buffers can
	-- still be remembered within this Neovim instance without serializing their contents.
	if not data and not vim.bo[buf].modified then
		return false
	end
	worktree = key(worktree)
	vim.t[tab].aero_code_win = win
	local previous = live[worktree]
	live[worktree] = { buf = buf, win = win, data = data }
	if data and config.options.persist_buffers and (not previous or not vim.deep_equal(previous.data, data)) then
		pending[worktree] = vim.deepcopy(data)
		if not scheduled then
			scheduled = true
			vim.defer_fn(M.flush, 250)
		end
	end
	return true
end

local function cursor(win, position)
	if type(position) ~= "table" or type(position[1]) ~= "number" or type(position[2]) ~= "number" then
		return
	end
	local buf = api.nvim_win_get_buf(win)
	local line = math.max(1, math.min(math.floor(position[1]), api.nvim_buf_line_count(buf)))
	local text = api.nvim_buf_get_lines(buf, line - 1, line, false)[1] or ""
	api.nvim_win_set_cursor(win, { line, math.max(0, math.min(math.floor(position[2]), #text)) })
end

--- Restore into a code window, falling back to the worktree directory when needed.
function M.restore(worktree, win)
	win = win or M.code_win()
	if not win then
		return false
	end
	local record = live[key(worktree)]
	local data = record and record.data
	if not record and config.options.persist_buffers then
		store.load()
		data = store.data.worktree_buffers[key(worktree)]
	end
	restoring = true
	local ok, err = pcall(api.nvim_win_call, win, function()
		if record and api.nvim_buf_is_valid(record.buf) and api.nvim_buf_is_loaded(record.buf) then
			api.nvim_win_set_buf(win, record.buf)
		elseif
			type(data) == "table"
			and type(data.path) == "string"
			and (
				(data.kind == "file" and vim.fn.filereadable(data.path) == 1)
				or ((data.kind == "directory" or data.kind == "oil") and vim.fn.isdirectory(data.path) == 1)
			)
		then
			local oil_ok, oil
			if data.kind == "oil" then
				oil_ok, oil = pcall(require, "oil")
			end
			if oil_ok and oil.open then
				local saved = data
				oil.open(data.path, {}, function(err)
					if not err and api.nvim_win_is_valid(win) then
						local now = describe(api.nvim_win_get_buf(win), win)
						if now and now.kind == "oil" and now.path == saved.path then
							cursor(win, saved.cursor)
							M.remember(win)
						end
					end
				end)
			else
				vim.cmd("keepalt hide edit " .. vim.fn.fnameescape(data.path))
			end
		else
			data = nil
			vim.cmd("keepalt hide edit " .. vim.fn.fnameescape(worktree))
		end
		if data then
			cursor(win, data.cursor)
		end
	end)
	restoring = false
	if not ok then
		vim.notify("aero: can't restore worktree buffer: " .. tostring(err), vim.log.levels.ERROR)
		return false
	end
	M.remember(win)
	return true
end

function M.forget(worktree)
	worktree = key(worktree)
	live[worktree], pending[worktree] = nil, nil
	for _, tab in ipairs(api.nvim_list_tabpages()) do
		local assigned = vim.t[tab].aero_worktree
		if assigned and key(assigned) == worktree then
			vim.t[tab].aero_worktree = nil
		end
	end
	store.load()
	if store.data.worktree_buffers[worktree] then
		store.remove_worktree_buffer(worktree)
	end
end

function M.setup()
	if state_file ~= config.options.state_file then
		live, pending = {}, {}
		state_file = config.options.state_file
	end
	local group = api.nvim_create_augroup("aero.buffers", { clear = true })
	api.nvim_create_autocmd({ "BufEnter", "WinEnter", "BufLeave", "WinLeave", "TabLeave", "BufFilePost" }, {
		group = group,
		callback = function()
			M.remember(api.nvim_get_current_win())
		end,
	})
	api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			M.remember()
			for _, record in ipairs(vim.tbl_values(live)) do
				if api.nvim_win_is_valid(record.win) and api.nvim_win_get_buf(record.win) == record.buf then
					M.remember(record.win)
				end
			end
			M.flush()
		end,
	})
end

return M
