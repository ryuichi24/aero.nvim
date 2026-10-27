-- Worktree change review: prepared Git data, scratch views, and explicit feedback drafts.
local api = vim.api
local git = require("aero.review.git")
local tree = require("aero.review.tree")
local M = {}
local active
local diff_namespace = api.nvim_create_namespace("Aero.review.diff")
local list_namespace = api.nvim_create_namespace("Aero.review.status")
local signs_namespace = api.nvim_create_namespace("Aero.review.signs")

function M.quote()
	if active and not active.closed and api.nvim_get_current_buf() == active.diff_buf then
		active.feedback(vim.fn.mode():match("^[vV\022]") ~= nil)
		return true
	end

	return false
end

local function setup_highlights()
	local light = vim.o.background == "light"
	api.nvim_set_hl(
		0,
		"AeroReviewAdd",
		{ fg = light and "#16703c" or "#98c379", ctermfg = light and 2 or 10, default = true }
	)
	api.nvim_set_hl(
		0,
		"AeroReviewDelete",
		{ fg = light and "#b42318" or "#e06c75", ctermfg = light and 1 or 9, default = true }
	)
	api.nvim_set_hl(
		0,
		"AeroReviewChange",
		{ fg = light and "#8a6500" or "#e5c07b", ctermfg = light and 3 or 11, default = true }
	)
end

api.nvim_create_autocmd("ColorScheme", {
	group = api.nvim_create_augroup("Aero.review.highlights", { clear = true }),
	callback = setup_highlights,
})

local function notify(text)
	vim.notify("Aero: " .. text, vim.log.levels.WARN)
end

function M.command(action)
	if not active or active.closed then
		return notify("open a review first with :Aero review")
	end

	local actions = { diff = "toggle_diff", refresh = "refresh", base = "choose_base", ["local"] = "local_changes" }
	local method = actions[action]

	if not method then
		return notify("unknown review action: " .. tostring(action))
	end

	return active[method]()
end

local function put(buf, lines)
	if not api.nvim_buf_is_valid(buf) then
		return
	end

	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	api.nvim_buf_clear_namespace(buf, diff_namespace, 0, -1)
	api.nvim_buf_clear_namespace(buf, signs_namespace, 0, -1)

	if vim.bo[buf].filetype == "diff" then
		local in_hunk = false

		for i, line in ipairs(lines) do
			if line:match("^diff %-%-git ") then
				in_hunk = false
			end

			if line:match("^@@") then
				in_hunk = true
			end

			local sign = line:sub(1, 1)

			if in_hunk and (sign == "+" or sign == "-") then
				api.nvim_buf_set_extmark(buf, diff_namespace, i - 1, 0, {
					end_col = #line,
					hl_group = sign == "+" and "AeroReviewAdd" or "AeroReviewDelete",
					priority = 200,
				})
			end
		end
	end
end

local function label(path)
	return vim.fn.strtrans(path)
end

local function geometry()
	local width, height = vim.o.columns - 6, vim.o.lines - 7
	local left = math.max(18, math.floor(width * 0.32))
	return width, height, left
end

function M.open(path, base)
	setup_highlights()
	local dashboard = require("aero.dashboard")
	local preferred = require("aero.session_target").resolve("viewed")

	if not path then
		local ws = dashboard.selected_workspace()

		if vim.bo.filetype == "Aero" and not ws then
			notify("move the cursor to a workspace, worktree, or agent session first")
			return
		end

		path = dashboard.selected_worktree()
			or ws and ws.root
			or preferred and preferred.worktree
			or vim.t.aero_worktree
			or vim.fn.getcwd()
	end

	if vim.o.columns < 50 or vim.o.lines < 14 then
		notify("review needs at least 50 columns and 14 lines")
		return
	end

	if active then
		active.close(false)
	end

	vim.cmd.stopinsert()
	local view = {
		path = path,
		base = base,
		generation = 0,
		preview_generation = 0,
		previous = api.nvim_get_current_win(),
		collapsed = {},
		rows = {},
	}
	active = view
	local width, height, left = geometry()

	for _, name in ipairs({ "list", "diff" }) do
		local buf = api.nvim_create_buf(false, true)
		view[name .. "_buf"] = buf
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].filetype = name == "diff" and "diff" or "aero-review"
		vim.b[buf].aero_review = true
	end

	view.list_win = api.nvim_open_win(view.list_buf, true, {
		relative = "editor",
		row = 2,
		col = 2,
		width = left,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Worktree changes ",
		footer = " b base · L local · R refresh ",
	})
	view.diff_win = api.nvim_open_win(view.diff_buf, false, {
		relative = "editor",
		row = 2,
		col = left + 4,
		width = width - left - 2,
		height = height,
		style = "minimal",
		border = "rounded",
		title = " Diff ",
		footer = " Tab tree/controls · gf file · a quote ",
	})
	vim.wo[view.list_win].cursorline = true
	vim.wo[view.list_win].wrap = false
	vim.wo[view.diff_win].wrap = false
	view.group = api.nvim_create_augroup("Aero.review", { clear = true })

	function view.close(restore)
		if view.closed then
			return
		end

		view.closed = true
		api.nvim_del_augroup_by_id(view.group)

		for _, win in ipairs({ view.diff_win, view.list_win }) do
			if api.nvim_win_is_valid(win) then
				api.nvim_win_close(win, true)
			end
		end

		if view.feedback_win and api.nvim_win_is_valid(view.feedback_win) then
			api.nvim_win_close(view.feedback_win, true)
		end

		if view.feedback_buf and api.nvim_buf_is_valid(view.feedback_buf) then
			api.nvim_buf_delete(view.feedback_buf, { force = true })
		end

		if active == view then
			active = nil
		end

		if restore ~= false and api.nvim_win_is_valid(view.previous) then
			api.nvim_set_current_win(view.previous)
		end
	end

	local function selected_node()
		local row = view.rows[api.nvim_win_get_cursor(view.list_win)[1]]
		return row and row.node
	end

	local function selected()
		local node = selected_node()
		return view.snapshot and node and node.item
	end

	function view.render_tree(key)
		local lines
		lines, view.rows = tree.render(view.tree, view.collapsed, require("aero.config").options.icons)
		local row, first_file

		for i, entry in ipairs(view.rows) do
			if entry.node.key == key then
				row = i
			end

			if not first_file and entry.node.item then
				first_file = i
			end
		end

		put(view.list_buf, #lines > 0 and lines or { "No changes" })
		api.nvim_buf_clear_namespace(view.list_buf, list_namespace, 0, -1)

		for i, row in ipairs(view.rows) do
			if row.node.item then
				local _, highlight = tree.status(row.node.item)
				api.nvim_buf_set_extmark(view.list_buf, list_namespace, i - 1, row.depth * 2 + 2, {
					end_col = #lines[i],
					hl_group = highlight,
					priority = 200,
				})
			end
		end

		api.nvim_win_set_cursor(view.list_win, { row or first_file or 1, 0 })
	end

	local function title(stale)
		if not api.nvim_win_is_valid(view.diff_win) then
			return
		end

		local comparison = view.base and ("BASE: " .. label(view.base) .. " · merge-base → HEAD; committed only")
			or "LOCAL · index + working tree; disk only"
		api.nvim_win_set_config(view.diff_win, { title = " " .. comparison .. " " })
		vim.wo[view.diff_win].winbar = (stale and "STALE — R refresh | " or "")
			.. (view.base and ("BASE: " .. label(view.base):gsub("%%", "%%%%")) or "LOCAL")
			.. " | Refreshed "
			.. (view.snapshot and view.snapshot.refreshed or "—")
		view.stale = stale
	end

	function view.render_preview()
		if not view.output then
			return
		end

		pcall(vim.treesitter.stop, view.diff_buf)
		local text = view.output

		if view.code_mode then
			text = view.content
		end

		local ft = view.code_mode and (vim.filetype.match({ filename = view.item.path }) or "text") or "diff"
		vim.bo[view.diff_buf].filetype = ft
		vim.bo[view.diff_buf].syntax = ft
		local lines =
			vim.split(text or "Code unavailable: " .. (view.content_error or "loading…"), "\n", { plain = true })

		if lines[#lines] == "" then
			table.remove(lines)
		end

		if #lines == 0 then
			lines = { "" }
		end

		if not view.code_mode and view.truncated then
			table.insert(lines, "[Diff truncated at 1 MiB]")
		end

		put(view.diff_buf, lines)
		vim.wo[view.diff_win].number = view.code_mode == true
		vim.wo[view.diff_win].relativenumber = false
		vim.wo[view.diff_win].signcolumn = view.code_mode and "yes:1" or "no"

		if view.code_mode and view.content then
			require("aero.review.signs").render(
				view.diff_buf,
				signs_namespace,
				view.output,
				view.item.status:sub(1, 1) == "D"
			)
		end

		if view.code_mode and view.content then
			pcall(vim.treesitter.start, view.diff_buf)
		end

		api.nvim_win_set_config(
			view.diff_win,
			{ footer = " " .. (view.code_mode and "Code" or "Diff") .. " · Tab tree/controls · gf file · a quote " }
		)
	end

	function view.toggle_diff()
		local cursor = api.nvim_win_get_cursor(view.diff_win)[1]
		local target, line = 1, nil

		if view.output then
			for i, text in ipairs(vim.split(view.output, "\n", { plain = true })) do
				local start = text:match("^@@ .* %+(%d+)")

				if start then
					line = tonumber(start)
				elseif line and (text:sub(1, 1) == "+" or text:sub(1, 1) == " ") then
					if view.code_mode and line <= cursor then
						target = i
					end

					if not view.code_mode and i <= cursor then
						target = line
					end

					line = line + 1
				end
			end
		end

		view.code_mode = not view.code_mode
		view.render_preview()
		api.nvim_win_set_cursor(
			view.diff_win,
			{ math.max(1, math.min(target, api.nvim_buf_line_count(view.diff_buf))), 0 }
		)
	end

	function view.preview()
		if view.closed or not view.snapshot then
			return
		end

		local node = selected_node()
		local item = node and node.item

		if node == view.preview_node and view.preview_snapshot == view.snapshot then
			return
		end

		view.preview_node = node
		view.preview_snapshot = view.snapshot
		view.item, view.output, view.content, view.content_error = item, nil, nil, nil
		pcall(vim.treesitter.stop, view.diff_buf)
		vim.bo[view.diff_buf].filetype = "diff"
		view.preview_generation = view.preview_generation + 1
		local generation = view.preview_generation
		put(view.diff_buf, {
			item and "Loading diff…"
				or (node and ("Folder: " .. label(node.path) .. "/") or "No changes in this comparison."),
			"",
			"Enter toggle folder / focus diff  h collapse / parent  l expand / child",
			"R refresh  b base ref  L local changes  q close",
			"gf open file  a quote hunk  Visual a quote selection",
			"",
			"Git reads files on disk; unsaved editor changes are not included.",
		})

		if not item then
			return
		end

		git.content(view.snapshot, item, function(out, err, truncated)
			if view.closed or generation ~= view.preview_generation then
				return
			end

			if out and out:find("\0", 1, true) then
				out, err = nil, "binary file"
			end

			if truncated then
				out, err = nil, "file exceeds 1 MiB"
			end

			view.content, view.content_error = out, err

			if view.code_mode then
				view.render_preview()
			end
		end)
		git.diff(view.snapshot, item, function(out, err, truncated)
			if view.closed or generation ~= view.preview_generation then
				return
			end

			if not out then
				return put(view.diff_buf, { "Could not read diff: " .. err, "Press R to refresh." })
			end

			view.output = out
			view.truncated = truncated
			view.render_preview()
		end)
	end

	function view.refresh()
		if view.closed then
			return
		end

		view.generation = view.generation + 1
		view.preview_generation = view.preview_generation + 1
		local generation, old = view.generation, selected_node()
		view.snapshot, view.item, view.output = nil, nil, nil
		view.rows = {}
		title(false)
		put(view.list_buf, { "Loading changes…" })
		put(view.diff_buf, { "Loading changes…" })
		git.collect(view.path, view.base, function(snapshot, err)
			if view.closed or generation ~= view.generation then
				return
			end

			if not snapshot then
				put(view.list_buf, { "Review unavailable" })
				put(
					view.diff_buf,
					vim.split(err .. "\nR retry  b choose another base  L local changes", "\n", { plain = true })
				)
				return
			end

			view.snapshot, view.path = snapshot, snapshot.worktree
			api.nvim_win_set_config(view.list_win, { title = " " .. label(vim.fs.basename(view.path)) .. " changes " })
			view.tree = tree.build(snapshot.items)
			view.render_tree(old and old.key)
			title(false)
			view.preview()
		end)
	end

	function view.toggle_directory()
		local node = selected_node()

		if not node or node.kind ~= "directory" then
			return
		end

		view.collapsed[node.path] = not view.collapsed[node.path] or nil
		view.render_tree(node.key)
		view.preview()
	end

	function view.tree_left()
		local row = view.rows[api.nvim_win_get_cursor(view.list_win)[1]]

		if not row then
			return
		end

		if row.node.kind == "directory" and not view.collapsed[row.node.path] then
			view.toggle_directory()
		elseif row.parent then
			api.nvim_win_set_cursor(view.list_win, { row.parent, 0 })
			view.preview()
		end
	end

	function view.tree_right()
		local index = api.nvim_win_get_cursor(view.list_win)[1]
		local row = view.rows[index]

		if not row then
			return
		end

		if row.node.kind == "directory" then
			if view.collapsed[row.node.path] then
				view.toggle_directory()
			elseif view.rows[index + 1] and view.rows[index + 1].parent == index then
				api.nvim_win_set_cursor(view.list_win, { index + 1, 0 })
				view.preview()
			end
		else
			view.preview()
			api.nvim_set_current_win(view.diff_win)
		end
	end

	function view.open_file()
		local item = selected()

		if not item or not view.snapshot then
			return
		end

		local file = vim.fs.joinpath(view.path, item.path)

		if not vim.uv.fs_stat(file) then
			return notify("file is deleted or missing; read its diff instead")
		end

		local line = view.code_mode and api.nvim_win_get_cursor(view.diff_win)[1] or nil

		if not view.code_mode and view.output and item == view.item then
			local cursor = api.nvim_win_get_cursor(view.diff_win)[1]

			for i, text in ipairs(api.nvim_buf_get_lines(view.diff_buf, 0, cursor, false)) do
				local start = text:match("^@@ .* %+(%d+)")

				if start then
					line = tonumber(start)
				elseif line and i < cursor and (text:sub(1, 1) == "+" or text:sub(1, 1) == " ") then
					line = line + 1
				end
			end
		end

		view.close()
		require("aero.navigation").open_worktree(view.path, function()
			local buf = vim.fn.bufnr(file)

			if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
				api.nvim_win_set_buf(0, buf)
			else
				vim.cmd("keepalt hide edit " .. vim.fn.fnameescape(file))
			end

			if line then
				api.nvim_win_set_cursor(0, { math.max(1, math.min(line, api.nvim_buf_line_count(0))), 0 })
			end
		end)
	end

	function view.feedback(visual)
		if not view.item or not view.output or view.output == "" then
			return
		end

		if view.code_mode and not view.content then
			return notify("code is unavailable; switch to the diff to quote it")
		end

		local lines = api.nvim_buf_get_lines(view.diff_buf, 0, -1, false)

		if visual then
			lines = vim.fn.getregion(
				vim.fn.getpos("v"),
				vim.fn.getpos("."),
				{ type = vim.fn.mode(), exclusive = vim.o.selection == "exclusive" }
			)
			vim.cmd("normal! " .. api.nvim_replace_termcodes("<Esc>", true, false, true))
		elseif not view.code_mode then
			local row = api.nvim_win_get_cursor(view.diff_win)[1]
			local first, last

			for i = row, 1, -1 do
				if lines[i]:match("^@@") then
					first = i
					break
				end
			end

			if first then
				last = #lines

				for i = first + 1, #lines do
					if lines[i]:match("^@@") then
						last = i - 1
						break
					end
				end

				lines = vim.list_slice(lines, first, last)
			end
		end

		local fence = "```"

		for ticks in table.concat(lines, "\n"):gmatch("`+") do
			if #ticks >= #fence then
				fence = string.rep("`", #ticks + 1)
			end
		end

		local snapshot, item = view.snapshot, view.item
		local text = ("Review feedback for worktree %s\nFile: %s%s\nComparison: %s; refreshed %s%s\n\n%s%s\n%s\n%s\n\nFeedback: "):format(
			vim.json.encode(view.path),
			vim.json.encode(item.path),
			item.old_path and (" (from " .. vim.json.encode(item.old_path) .. ")") or "",
			item.kind == "branch"
					and ("merge-base(" .. vim.json.encode(snapshot.base) .. ") " .. snapshot.merge_base .. " → " .. snapshot.head)
				or item.kind,
			snapshot.refreshed,
			view.stale and " (may be stale)" or "",
			fence,
			view.code_mode and vim.bo[view.diff_buf].filetype or "diff",
			table.concat(lines, "\n"),
			fence
		)
		local candidates = require("aero.session").list(view.path)

		local function append(s)
			if not s or view.closed then
				return
			end

			if view.feedback_session then
				s = view.feedback_session
			end

			if s.chat or s.job then
				view.feedback_session = s
				local buf = view.feedback_buf

				if not buf or not api.nvim_buf_is_valid(buf) then
					buf = api.nvim_create_buf(false, true)
					view.feedback_buf = buf
					vim.bo[buf].bufhidden = "hide"
					vim.bo[buf].filetype = "markdown"

					local function send()
						local row = api.nvim_win_get_cursor(0)[1]
						local content = api.nvim_buf_get_lines(buf, 0, -1, false)

						if vim.trim(content[row] or "") ~= "/send" then
							return false
						end

						if
							not vim.tbl_contains(require("aero.session").all(), s)
							or (s.chat and s.chat.state == "exited")
						then
							notify("feedback session is no longer running")
							return true
						end

						table.remove(content, row)
						local message = vim.trim(table.concat(content, "\n"))

						if message == "" then
							return true
						end

						if s.chat then
							s.chat:prompt(message)
						else
							local ok, err = pcall(vim.fn.chansend, s.job, "\027[200~" .. message .. "\027[201~\r")

							if not ok then
								notify(tostring(err))
								return true
							end
						end

						api.nvim_buf_set_lines(buf, 0, -1, false, {})
						vim.cmd.stopinsert()
						api.nvim_win_close(view.feedback_win, true)

						if not view.closed then
							api.nvim_set_current_win(view.diff_win)
						end

						return true
					end

					vim.keymap.set("n", "<CR>", function()
						if send() then
							return
						end

						local row = api.nvim_win_get_cursor(0)[1]
						api.nvim_buf_set_lines(buf, row, row, false, { "" })
						api.nvim_win_set_cursor(0, { row + 1, 0 })
						vim.cmd.startinsert()
					end, { buffer = buf })
					vim.keymap.set("i", "<CR>", function()
						if not send() then
							api.nvim_feedkeys(api.nvim_replace_termcodes("<CR>", true, false, true), "in", false)
						end
					end, { buffer = buf })
					vim.keymap.set("n", "q", function()
						api.nvim_win_close(view.feedback_win, true)

						if not view.closed then
							api.nvim_set_current_win(view.diff_win)
						end
					end, { buffer = buf })
				end

				local draft = api.nvim_buf_get_lines(buf, 0, -1, false)

				if #draft == 1 and draft[1] == "" then
					draft = {}
				else
					table.insert(draft, "")
				end

				vim.list_extend(draft, vim.split(text, "\n", { plain = true }))
				api.nvim_buf_set_lines(buf, 0, -1, false, draft)

				if view.feedback_win and api.nvim_win_is_valid(view.feedback_win) then
					api.nvim_set_current_win(view.feedback_win)
				else
					local w = math.min(vim.o.columns - 10, 100)
					local h = math.max(4, math.floor((vim.o.lines - 7) * 0.5))
					view.feedback_win = api.nvim_open_win(buf, true, {
						relative = "editor",
						row = math.floor((vim.o.lines - h) / 2),
						col = math.floor((vim.o.columns - w) / 2),
						width = w,
						height = h,
						style = "minimal",
						border = "rounded",
						zindex = 60,
						title = " Review feedback · " .. s.name .. " ",
						footer = " /send then Enter · q keep draft and return ",
					})
				end

				api.nvim_win_set_cursor(view.feedback_win, { #draft, #draft[#draft] })

				if require("aero.config").options.start_insert then
					vim.cmd.startinsert()
				end
			else
				notify("feedback session is no longer running")
			end
		end

		if #candidates == 0 then
			return notify("start an agent session in this worktree before adding feedback")
		end

		if preferred and vim.tbl_contains(candidates, preferred) then
			return append(preferred)
		end

		if #candidates == 1 then
			return append(candidates[1])
		end

		vim.ui.select(candidates, {
			prompt = "Review feedback to agent",
			format_item = function(s)
				return s.name .. " (" .. s.agent .. ")"
			end,
		}, append)
	end

	function view.choose_base()
		git.branches(view.path, function(branches, err)
			if view.closed then
				return
			end

			if not branches then
				return notify(err)
			end

			if #branches == 0 then
				return notify("no branches available for review")
			end

			vim.ui.select(branches, { prompt = "Review committed changes against base branch:" }, function(ref)
				if view.closed or not ref then
					return
				end

				view.base = ref
				view.refresh()
			end)
		end)
	end

	function view.local_changes()
		view.base = nil
		view.refresh()
	end

	for _, buf in ipairs({ view.list_buf, view.diff_buf }) do
		local function map(key, fn, desc, mode)
			vim.keymap.set(mode or "n", key, fn, { buffer = buf, nowait = true, desc = "Aero review: " .. desc })
		end

		map("q", view.close, "close")
		map("<Esc>", view.close, "close")
		map("gf", view.open_file, "open file")
		map("<Tab>", function()
			view.preview()
			api.nvim_set_current_win(api.nvim_get_current_win() == view.list_win and view.diff_win or view.list_win)
		end, "switch pane")

		if buf == view.list_buf then
			map("R", view.refresh, "refresh")
			map("D", view.toggle_diff, "toggle diff/code")
			map("b", view.choose_base, "choose branch base")
			map("L", view.local_changes, "local changes")
		end
	end

	vim.keymap.set("n", "<CR>", function()
		local node = selected_node()

		if node and node.kind == "directory" then
			return view.toggle_directory()
		end

		view.preview()
		api.nvim_set_current_win(view.diff_win)
	end, { buffer = view.list_buf, desc = "Aero review: toggle folder or focus diff" })
	vim.keymap.set(
		"n",
		"h",
		view.tree_left,
		{ buffer = view.list_buf, desc = "Aero review: collapse folder or go to parent" }
	)
	vim.keymap.set("n", "l", view.tree_right, { buffer = view.list_buf, desc = "Aero review: expand folder or enter" })
	vim.keymap.set("n", "a", function()
		view.feedback(false)
	end, { buffer = view.diff_buf, desc = "Aero review: quote hunk" })

	for _, key in ipairs({ "a", require("aero.config").options.quote_key or "a" }) do
		vim.keymap.set("x", key, function()
			view.feedback(true)
		end, { buffer = view.diff_buf, desc = "Aero review: quote selection" })
	end

	api.nvim_create_autocmd("CursorMoved", {
		group = view.group,
		buffer = view.list_buf,
		callback = function()
			view.cursor_generation = (view.cursor_generation or 0) + 1
			local generation = view.cursor_generation
			vim.defer_fn(function()
				if not view.closed and generation == view.cursor_generation then
					view.preview()
				end
			end, 60)
		end,
	})
	api.nvim_create_autocmd({ "BufWritePost", "FocusGained" }, {
		group = view.group,
		callback = function(event)
			if
				view.snapshot
				and (event.event == "FocusGained" or require("aero.storage").inside(event.file, view.path))
			then
				title(true)
			end
		end,
	})
	api.nvim_create_autocmd("WinClosed", {
		group = view.group,
		callback = function(event)
			if tonumber(event.match) == view.list_win or tonumber(event.match) == view.diff_win then
				view.close()
			end
		end,
	})
	api.nvim_create_autocmd("VimResized", {
		group = view.group,
		callback = function()
			if vim.o.columns < 50 or vim.o.lines < 14 then
				return view.close()
			end

			local w, h, l = geometry()
			api.nvim_win_set_config(view.list_win, { width = l, height = h })
			api.nvim_win_set_config(view.diff_win, { col = l + 4, width = w - l - 2, height = h })
		end,
	})
	view.refresh()
	return view
end

return M
