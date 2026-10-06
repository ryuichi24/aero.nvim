-- Runtime attention events. Block identity distinguishes events from repeated renders.
local M = {}
local api = vim.api
local entries = {}
local seen = setmetatable({}, { __mode = "k" })
local serial = 0

function M.add(chat, kind, block, text)
	if chat.replaying or chat.task_reloading or not block then
		return
	end
	local kinds = seen[block] or {}
	seen[block] = kinds
	if kinds[kind] then
		return
	end
	kinds[kind] = true
	serial = serial + 1
	local s = chat.s
	local binding = s.task_binding
	local saved = require("aero.store").find_session(s.worktree, s.name)
	local assignment = saved and saved.task_assignment
	if not chat.inbox_workspace then
		chat.inbox_workspace = require("aero.git").main_root(s.worktree) or s.worktree
	end
	table.insert(entries, {
		key = tostring(serial),
		order = serial,
		chat = chat,
		session = s,
		kind = kind,
		block = block,
		text = text or block.title or block.text or "Turn completed",
		workspace = binding and binding.workspace and binding.workspace.root
			or assignment and assignment.workspace_root
			or chat.inbox_workspace,
		ticket = binding and binding.ticket_id or assignment and assignment.ticket_id,
	})
end

function M.items()
	local sessions = require("aero.session").all()
	-- Resolved permissions and forgotten/replaced conversations cannot be opened.
	entries = vim.tbl_filter(function(e)
		return vim.tbl_contains(sessions, e.session)
			and e.session.chat == e.chat
			and (e.kind ~= "permission" or e.chat.permission and e.chat.permission.block == e.block)
	end, entries)
	return vim.tbl_filter(function(e)
		return not e.read and not e.dismissed
	end, entries)
end

function M.dismiss(entry)
	entry.dismissed = true
end

function M.read(entry)
	entry.read = true
end

function M.select(entry)
	local s, chat = entry.session, entry.chat
	if
		not vim.tbl_contains(require("aero.session").all(), s)
		or s.chat ~= chat
		or not api.nvim_buf_is_valid(chat.buf)
		or entry.kind == "permission" and (not chat.permission or chat.permission.block ~= entry.block)
	then
		vim.notify("Aero: inbox event is no longer available", vim.log.levels.INFO)
		return
	end
	if vim.fn.isdirectory(s.worktree) == 0 then
		vim.notify("Aero: inbox worktree is no longer available", vim.log.levels.WARN)
		return
	end
	local win = require("aero").open_worktree(s.worktree)
	if not win then
		return
	end
	local panel = require("aero.panel")
	if panel.enabled() then
		win = panel.open()
	end
	-- Show the existing transcript, including exited agents, without starting/resuming.
	win = require("aero.session").prepare_win(win)
	api.nvim_win_set_buf(win, chat.buf)
	if panel.enabled() then
		panel.shown(s)
	end
	api.nvim_set_current_win(win)
	vim.cmd.stopinsert()
	chat:goto_block(entry.block, entry.kind == "permission")
	M.read(entry)
end

local function label(e)
	return ("  [%s] %s [%s]%s · %s"):format(
		e.kind,
		e.session.name,
		e.session.agent,
		e.ticket and " · " .. e.ticket or "",
		e.text
	)
end

function M.open()
	require("aero.picker").open({
		title = "attention events",
		filetype = "aero_inbox",
		live = true,
		items = M.items,
		label = label,
		group = function(e)
			local worktree = vim.fn.fnamemodify(e.session.worktree, ":~")
			return e.workspace and vim.fn.fnamemodify(e.workspace, ":~") .. " → " .. worktree or worktree
		end,
		search = function(e)
			return (e.workspace or "") .. " " .. e.session.worktree .. " " .. label(e)
		end,
		sort = function(a, b)
			return a.order > b.order
		end,
		select = M.select,
		actions = { d = M.dismiss, r = M.read },
		footer = " j/k: select · i: filter · Enter: open/read · r: read · d: dismiss · q: close ",
	})
end

return M
