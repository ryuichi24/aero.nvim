-- Zoom a panel in a temporary tab, leaving the original windows and layout intact.
local api = vim.api
local M = {}
local views = {}
local global_key

function M.setup()
	if global_key then
		local map = vim.fn.maparg(global_key, "n", false, true)
		if map.callback == M.toggle and map.buffer == 0 then
			vim.keymap.del("n", global_key)
		end
	end
	global_key = require("aero.config").options.fullscreen_key
	if global_key then
		vim.keymap.set("n", global_key, M.toggle, { desc = "Aero: toggle fullscreen" })
	end
end

function M.active()
	return views[api.nvim_get_current_tabpage()]
end

function M.close(kind)
	local view = M.active()
	if not view or (kind and view.kind ~= kind) then
		return false
	end
	-- Do not force-close: any new unsaved buffers opened here must be kept safe.
	view.closing = true
	local ok, err = pcall(vim.cmd.tabclose)
	if not ok then
		view.closing = nil
		vim.notify("aero: can't leave fullscreen: " .. tostring(err), vim.log.levels.ERROR)
		return true
	end
	if api.nvim_tabpage_is_valid(view.tab) then
		api.nvim_set_current_tabpage(view.tab)
		if api.nvim_win_is_valid(view.focus) then
			api.nvim_set_current_win(view.focus)
		end
	end
	require("aero.events").emit(
		"fullscreen_exited",
		{ kind = view.kind, tab = view.tab, win = view.source, buf = view.buf }
	)
	return true
end

local function copy_window(source, target)
	api.nvim_win_set_buf(target, api.nvim_win_get_buf(source))
	for name, info in pairs(api.nvim_get_all_options_info()) do
		if info.scope == "win" then
			local value = api.nvim_get_option_value(name, { win = source, scope = "local" })
			pcall(api.nvim_set_option_value, name, value, { win = target, scope = "local" })
		end
	end
	vim.wo[target].winfixwidth = false
	vim.wo[target].winfixheight = false
	local saved = api.nvim_win_call(source, vim.fn.winsaveview)
	api.nvim_win_call(target, function()
		vim.fn.winrestview(saved)
	end)
end

function M.toggle()
	if M.close() then
		return
	end
	local source = api.nvim_get_current_win()
	local tab = api.nvim_get_current_tabpage()
	local buf = api.nvim_win_get_buf(source)
	local session = require("aero.session")
	local s = session.from_buf(buf)
	local key = vim.b[buf].aero_chat_key
	if key then
		for _, candidate in ipairs(session.all()) do
			if candidate.key == key then
				s = candidate
				break
			end
		end
	end
	local prompt
	if s and s.chat then
		for _, win in ipairs(api.nvim_tabpage_list_wins(tab)) do
			local b = api.nvim_win_get_buf(win)
			if b == s.buf then
				source = win
			elseif b == s.chat.prompt_buf then
				prompt = win
			end
		end
	end
	local kind = s and "agent"
		or vim.b[buf].aero_term and "terminal"
		or vim.bo[buf].filetype == "Aero" and "dashboard"
		or "editor"
	-- Reuse an existing zoom of this panel if the user switched back to its original tab.
	for zoom, view in pairs(views) do
		if
			view.tab == tab
			and view.source == source
			and view.buf == api.nvim_win_get_buf(source)
			and api.nvim_tabpage_is_valid(zoom)
		then
			api.nvim_set_current_tabpage(zoom)
			return
		end
	end
	local focus = api.nvim_get_current_win()
	local cwd = vim.fn.getcwd()
	local worktree = vim.t.aero_worktree
	vim.cmd("tabnew")
	local zoom = api.nvim_get_current_tabpage()
	local win = api.nvim_get_current_win()
	vim.bo[api.nvim_win_get_buf(win)].bufhidden = "wipe"
	views[zoom] = { tab = tab, source = source, focus = focus, kind = kind, buf = api.nvim_win_get_buf(source) }
	vim.t.aero_fullscreen = true
	vim.t.aero_worktree = worktree
	vim.cmd.tcd(vim.fn.fnameescape(cwd))
	copy_window(source, win)
	if kind == "agent" then
		require("aero.panel").attach(win, s)
	elseif kind == "dashboard" then
		require("aero.dashboard").attach(win)
		vim.wo[win].winfixwidth = false
	end
	if prompt then
		local pw = api.nvim_open_win(api.nvim_win_get_buf(prompt), false, {
			split = "below",
			win = win,
			height = api.nvim_win_get_height(prompt),
		})
		copy_window(prompt, pw)
		vim.wo[pw].winfixheight = true
		require("aero.layout").track(pw, "prompt", s.key)
		if prompt == focus then
			api.nvim_set_current_win(pw)
		end
	end
	require("aero.events").emit(
		"fullscreen_entered",
		{ kind = kind, tab = zoom, source_tab = tab, win = win, source_win = source, buf = api.nvim_win_get_buf(win) }
	)
end

function M.bind(buf)
	require("aero.layout").bind(buf)
	local key = require("aero.config").options.fullscreen_key
	if key then
		vim.keymap.set("n", key, M.toggle, { buffer = buf, desc = "Aero: toggle fullscreen" })
	end
end

api.nvim_create_autocmd("TabClosed", {
	callback = function()
		for tab, view in pairs(views) do
			if not api.nvim_tabpage_is_valid(tab) then
				views[tab] = nil
				if not view.closing then
					vim.schedule(function()
						require("aero.events").emit(
							"fullscreen_exited",
							{ kind = view.kind, tab = view.tab, win = view.source, buf = view.buf }
						)
					end)
				end
			end
		end
	end,
})

return M
