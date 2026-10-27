-- Non-destructive Mermaid previews for Markdown files and ACP transcripts.
local M = {}
local api = vim.api
local ns = api.nvim_create_namespace("Aero.mermaid")
local buffers, images, jobs, queue = {}, {}, {}, {}
local running, generation = 0, 0
local options
local pump, refresh, schedule
local viewer = require("aero.mermaid_view")
local progress_pending = false
local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function loading(buf, item)
	local job = item.job
	local elapsed = (vim.uv.hrtime() - (job.started or job.queued)) / 1e9
	local text

	if job.state == "queued" then
		local position = 1

		for index, pending in ipairs(queue) do
			if pending == job then
				position = index
				break
			end
		end

		text = ("Queued for PNG · position %d · %.1fs waiting"):format(position, elapsed)
	else
		text = ("Rendering PNG… · %.1fs"):format(elapsed)
	end

	local frame = frames[math.floor(vim.uv.hrtime() / 1e6 / 150) % #frames + 1]
	item.mark = api.nvim_buf_set_extmark(buf, ns, item.row, 0, {
		id = item.mark,
		virt_lines = { { { ("  %s Mermaid %d/%d · %s"):format(frame, item.index, item.total, text), "Comment" } } },
	})
end

local function animate()
	if progress_pending then
		return
	end

	progress_pending = true
	local epoch = generation
	vim.defer_fn(function()
		if epoch ~= generation then
			return
		end

		progress_pending = false
		local pending = false

		for buf, state in pairs(buffers) do
			if
				api.nvim_buf_is_valid(buf)
				and api.nvim_buf_is_loaded(buf)
				and state.tick == api.nvim_buf_get_changedtick(buf)
			then
				for _, item in ipairs(state.loading or {}) do
					if item.job.state == "queued" or item.job.state == "running" then
						loading(buf, item)
						pending = true
					end
				end
			end
		end

		if pending then
			animate()
		end
	end, 150)
end

-- Render complete Mermaid fences, including a single diagram wrapped in md/markdown.
function M.blocks(lines)
	local result, fence = {}, nil

	for row, line in ipairs(lines) do
		local indent, ticks, rest = line:match("^( *)(`+)(.*)$")

		if not ticks then
			indent, ticks, rest = line:match("^( *)(~+)(.*)$")
		end

		if ticks and #indent <= 3 and #ticks >= 3 then
			if fence then
				if ticks:sub(1, 1) == fence.char and #ticks >= fence.length and rest:match("^%s*$") then
					if fence.mermaid and #fence.source > 0 then
						table.insert(result, {
							start_row = fence.row,
							row = row - 1,
							anchor_row = row - 2,
							source = table.concat(fence.source, "\n"),
						})
					elseif fence.markdown then
						local nested = M.blocks(fence.source)

						if #nested == 1 then
							local diagram, only_diagram = nested[1], true

							for index, text in ipairs(fence.source) do
								if
									(index <= diagram.start_row or index > diagram.row + 1) and not text:match("^%s*$")
								then
									only_diagram = false
								end
							end

							if only_diagram then
								diagram.anchor_row = fence.row + 1 + diagram.anchor_row
								diagram.start_row, diagram.row = fence.row, row - 1
								table.insert(result, diagram)
							end
						end
					end

					fence = nil
				elseif fence.mermaid or fence.markdown then
					table.insert(fence.source, line:sub(math.min(#(line:match("^ *") or ""), fence.indent) + 1))
				end
			else
				fence = {
					char = ticks:sub(1, 1),
					length = #ticks,
					indent = #indent,
					mermaid = vim.trim(rest) == "mermaid",
					source = {},
					markdown = vim.trim(rest) == "markdown" or vim.trim(rest) == "md",
					row = row - 1,
				}
			end
		elseif fence and (fence.mermaid or fence.markdown) then
			table.insert(fence.source, line:sub(math.min(#(line:match("^ *") or ""), fence.indent) + 1))
		end
	end

	return result
end

local function clear(id)
	local item = images[id]

	if item then
		pcall(item.image.clear, item.image)

		-- Retired objects remain in image.nvim's registry; prevent window rerenders.
		item.image.window = -1
		images[id] = nil
	end
end

local function status(buf, row, text, group)
	api.nvim_buf_set_extmark(buf, ns, row, 0, {
		virt_text = { { "  " .. text, group or "Comment" } },
		virt_text_pos = "eol",
	})
end

local function request(source, buf)
	local theme = options.theme == "auto" and (vim.o.background == "dark" and "dark" or "default") or options.theme
	local key = vim.fn.sha256(vim.json.encode({ source, options.cmd, theme, options.background, options.scale }))
	local job = jobs[key]

	if job and job.state == "ready" and vim.fn.filereadable(job.path) ~= 1 then
		jobs[key], job = nil, nil
	end

	if not job then
		local directory = vim.fn.stdpath("cache") .. "/aero/mermaid"
		job = {
			key = key,
			source = source,
			theme = theme,
			path = directory .. "/" .. key .. ".png",
			waiters = {},
			state = "queued",
			queued = vim.uv.hrtime(),
		}
		jobs[key] = job

		if vim.fn.filereadable(job.path) == 1 then
			job.state = "ready"
		else
			table.insert(queue, job)
		end
	end

	job.waiters[buf] = true
	pump()
	return job
end

pump = function()
	while running < math.max(1, options.concurrency or 4) and #queue > 0 do
		local job = table.remove(queue, 1)
		local input = vim.fn.tempname() .. ".mmd"
		local command = vim.deepcopy(options.cmd)
		vim.list_extend(command, {
			"-i",
			input,
			"-o",
			job.path,
			"-t",
			job.theme,
			"-b",
			options.background,
			"-s",
			tostring(options.scale),
		})
		local epoch = generation

		local function finish(code, detail)
			vim.fn.delete(input)

			if epoch ~= generation then
				return
			end

			running = running - 1

			if code == 0 and vim.fn.filereadable(job.path) == 1 then
				job.state = "ready"
			else
				vim.fn.delete(job.path)
				job.state = "failed"
				local message = vim.trim(detail or "")

				if message == "" then
					message = "Mermaid CLI exited with code " .. tostring(code) .. " without producing a PNG"
				end

				job.error = message:gsub("%s+", " "):sub(1, 240)
			end

			for buf in pairs(job.waiters) do
				schedule(buf, 0)
			end

			pump()
		end

		job.state, job.started, running = "running", vim.uv.hrtime(), running + 1
		local ok, err = pcall(function()
			vim.fn.mkdir(vim.fn.fnamemodify(job.path, ":h"), "p")
			assert(vim.fn.writefile(vim.split(job.source, "\n", { plain = true }), input) == 0)
			job.process = vim.system(command, { text = true, timeout = 60000 }, function(result)
				vim.schedule(function()
					finish(result.code, result.stderr ~= "" and result.stderr or result.stdout)
				end)
			end)
		end)

		if not ok then
			finish(1, tostring(err))
		end
	end
end
refresh = function(buf)
	if not options or not options.enabled or not api.nvim_buf_is_valid(buf) or not api.nvim_buf_is_loaded(buf) then
		return
	end

	local state = buffers[buf]

	if not state then
		return
	end

	local expanded = viewer.active()

	if
		expanded
		and api.nvim_win_is_valid(expanded.win)
		and api.nvim_win_get_tabpage(expanded.win) == api.nvim_get_current_tabpage()
	then
		-- Kitty graphics are independent of Neovim's floating-window text layers.
		for id, item in pairs(images) do
			if item.buf == buf then
				clear(id)
			end
		end

		state.loading = {}
		return
	end

	api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	state.buttons = {}
	state.loading = {}
	local keep = {}
	local windows = vim.tbl_filter(function(win)
		return api.nvim_win_get_buf(win) == buf
	end, api.nvim_tabpage_list_wins(0))

	if vim.bo[buf].filetype == "markdown" and #windows > 0 then
		local tick = api.nvim_buf_get_changedtick(buf)

		if state.tick ~= tick then
			state.tick, state.blocks = tick, M.blocks(api.nvim_buf_get_lines(buf, 0, -1, false))
		end

		local last_visible

		for index, block in ipairs(state.blocks) do
			local visible = vim.tbl_filter(function(win)
				local info = vim.fn.getwininfo(win)[1]
				return info
					and block.row + 1 >= info.topline - options.max_height
					and block.row + 1 <= info.botline + options.max_height
			end, windows)

			if #visible == 0 then
				goto continue
			end

			last_visible = index
			local ok, image_api = pcall(require, "image")

			if not ok then
				status(buf, block.row, "Mermaid: install and configure image.nvim", "DiagnosticWarn")
			elseif vim.fn.executable(options.cmd[1]) ~= 1 then
				status(buf, block.row, "Mermaid: executable not found: " .. options.cmd[1], "DiagnosticWarn")
			else
				local job = request(block.source, buf)

				if job.state ~= "ready" then
					if job.state == "failed" then
						status(buf, block.anchor_row, "Mermaid: " .. job.error, "DiagnosticError")
					else
						local item = { job = job, row = block.anchor_row, index = index, total = #state.blocks }
						table.insert(state.loading, item)
						loading(buf, item)
						animate()
					end
				else
					local label = " [Expand diagram"
						.. (options.preview_key and (" · " .. options.preview_key) or "")
						.. "] "
					api.nvim_buf_set_extmark(buf, ns, block.anchor_row, 0, {
						virt_text = { { label, "Special" } },
						virt_text_pos = "right_align",
						priority = 250,
					})
					state.buttons[block.anchor_row] = { label = label, block = block }

					for _, win in ipairs(visible) do
						-- Markdown formatters can conceal the closing fence's entire
						-- line, including its virt_lines. Pad after the last source line.
						local anchor = block.anchor_row
						local id = ("aero-mermaid:%d:%d:%d:%s"):format(win, buf, block.row, job.key)
						keep[id] = true
						local item = images[id]
						local success, err = pcall(function()
							if not item then
								local image = image_api.from_file(job.path, {
									id = id,
									namespace = "aero-mermaid",
									window = win,
									buffer = buf,
									with_virtual_padding = true,
									x = 0,
									y = anchor,
									width = options.max_width,
									height = options.max_height,
								})
								assert(image, "could not load generated image")

								-- from_file may return a previously retired object for this ID.
								image.window, image.buffer = win, buf

								if image.geometry then
									image.geometry.width, image.geometry.height = options.max_width, options.max_height
								end

								item = { image = image, buf = buf, win = win }
								images[id] = item
							end

							-- Start below the whole anchor line, including wrapped screen rows.
							local text = api.nvim_buf_get_lines(buf, anchor, anchor + 1, false)[1] or ""
							local first = vim.fn.screenpos(win, anchor + 1, 1)
							local last = vim.fn.screenpos(win, anchor + 1, math.max(1, #text))
							item.image.render_offset_top = first.row > 0
									and last.row > 0
									and math.max(0, last.row - first.row)
								or 0
							item.image:render({ x = 0, y = anchor })
						end)

						if not success then
							status(
								buf,
								block.row,
								"Mermaid: " .. tostring(err):gsub("%s+", " "):sub(1, 180),
								"DiagnosticError"
							)
						end
					end
				end
			end

			::continue::
		end

		-- Visible requests take the worker slots first. Warm the next diagrams
		-- while the user reads, without launching the entire document at once.
		if last_visible and package.loaded.image and vim.fn.executable(options.cmd[1]) == 1 then
			for index = last_visible + 1, math.min(#state.blocks, last_visible + (options.prefetch or 2)) do
				request(state.blocks[index].source, buf)
			end
		end
	end

	for id, item in pairs(images) do
		if item.buf == buf and not keep[id] then
			clear(id)
		end
	end
end
schedule = function(buf, delay)
	if not options or not options.enabled then
		return
	end

	local state = buffers[buf]

	if not state then
		return
	end

	-- Throttle text changes instead of debouncing: continuous ACP streaming must
	-- not postpone previews forever. Viewport changes can request an immediate pass.
	if state.scheduled and delay ~= 0 then
		return
	end

	state.pending = (state.pending or 0) + 1
	state.scheduled = true
	local token, epoch = state.pending, generation
	vim.defer_fn(function()
		if epoch == generation and buffers[buf] == state and state.pending == token then
			state.scheduled = false
			refresh(buf)
		end
	end, delay or 300)
end

function M.preview(buf, win, row)
	if not options or not options.enabled then
		return false
	end

	buf, win = buf or api.nvim_get_current_buf(), win or api.nvim_get_current_win()
	row = row or (api.nvim_win_get_cursor(win)[1] - 1)

	for _, block in ipairs(M.blocks(api.nvim_buf_get_lines(buf, 0, -1, false))) do
		if row >= block.start_row and row <= block.row then
			local job = request(block.source, buf)

			if job.state == "ready" then
				return viewer.toggle(job.path, job.key, function()
					for source in pairs(buffers) do
						schedule(source, 0)
					end
				end)
			end

			vim.notify(job.state == "failed" and job.error or "Mermaid diagram is still rendering", vim.log.levels.INFO)
			return false
		end
	end

	return false
end

function M.click(mouse)
	if not mouse.winid or mouse.winid == 0 or not api.nvim_win_is_valid(mouse.winid) then
		return false
	end

	local buf = api.nvim_win_get_buf(mouse.winid)
	local state = buffers[buf]

	if not state then
		return false
	end

	local info = vim.fn.getwininfo(mouse.winid)[1]

	if not info then
		return false
	end

	for anchor, button in pairs(state.buttons or {}) do
		local position = vim.fn.screenpos(mouse.winid, anchor + 1, 1)
		local last = info.wincol + info.width - 1
		local first = math.max(info.wincol + info.textoff, last - vim.fn.strdisplaywidth(button.label) + 1)

		if
			position.row > 0
			and mouse.screenrow == position.row
			and mouse.screencol >= first
			and mouse.screencol <= last
		then
			vim.schedule(function()
				if api.nvim_win_is_valid(mouse.winid) and api.nvim_win_get_buf(mouse.winid) == buf then
					api.nvim_set_current_win(mouse.winid)
					M.preview(buf, mouse.winid, anchor)
				end
			end)
			return true
		end
	end

	return false
end

local function restore_bindings(buf, state)
	if not api.nvim_buf_is_valid(buf) then
		return
	end

	api.nvim_buf_call(buf, function()
		for lhs, binding in pairs(state.bindings or {}) do
			local current = vim.fn.maparg(lhs, "n", false, true)

			if current.callback == binding.callback then
				vim.keymap.del("n", lhs, { buffer = buf })

				if binding.previous.buffer == 1 then
					vim.fn.mapset("n", false, binding.previous)
				end
			end
		end
	end)
	state.bindings = nil
end

local function bind(buf, state)
	if state.bindings then
		return
	end

	state.bindings = {}

	local function set(lhs, callback, expr)
		local previous = api.nvim_buf_call(buf, function()
			return vim.fn.maparg(lhs, "n", false, true)
		end)
		state.bindings[lhs] = { previous = previous, callback = callback }
		vim.keymap.set("n", lhs, callback, { buffer = buf, expr = expr, desc = "Aero: expand Mermaid diagram" })
		return previous
	end

	if options.preview_key then
		set(options.preview_key, function()
			M.preview()
		end, false)
	end

	local previous
	previous = set("<LeftMouse>", function()
		if M.click(vim.fn.getmousepos()) then
			return ""
		end

		if previous.callback then
			if previous.expr == 1 then
				return previous.callback()
			end

			vim.schedule(previous.callback)
			return ""
		end

		return previous.rhs and previous.rhs ~= "" and previous.rhs or "<LeftMouse>"
	end, true)
end

local function attach(buf)
	if not api.nvim_buf_is_valid(buf) or vim.bo[buf].filetype ~= "markdown" then
		return
	end

	if not buffers[buf] then
		buffers[buf] = {}
		api.nvim_buf_attach(buf, false, {
			on_lines = function()
				schedule(buf)
			end,
			on_detach = function()
				buffers[buf] = nil
				vim.schedule(function()
					for id, item in pairs(images) do
						if item.buf == buf then
							clear(id)
						end
					end
				end)
			end,
		})
	end

	bind(buf, buffers[buf])
	schedule(buf, 0)
end

function M.setup()
	generation = generation + 1
	progress_pending = false
	viewer.close()

	for _, job in pairs(jobs) do
		if job.process and job.state == "running" then
			job.process:kill(15)
		end
	end

	for id in pairs(images) do
		clear(id)
	end

	jobs, queue, running = {}, {}, 0
	options = require("aero.config").options.mermaid
	local group = api.nvim_create_augroup("Aero.mermaid", { clear = true })

	for buf in pairs(buffers) do
		restore_bindings(buf, buffers[buf])
		buffers[buf].scheduled = false
		buffers[buf].loading = {}

		if api.nvim_buf_is_valid(buf) then
			api.nvim_buf_clear_namespace(buf, ns, 0, -1)
		end
	end

	if not options or not options.enabled then
		return
	end

	api.nvim_create_autocmd({ "FileType", "BufWinEnter", "BufEnter" }, {
		group = group,
		callback = function(event)
			if buffers[event.buf] and vim.bo[event.buf].filetype ~= "markdown" then
				restore_bindings(event.buf, buffers[event.buf])
			end

			attach(event.buf)

			if buffers[event.buf] then
				schedule(event.buf, 0)
			end
		end,
	})
	api.nvim_create_autocmd({ "WinNew", "WinScrolled", "WinResized", "TabEnter", "WinClosed", "BufWinLeave" }, {
		group = group,
		callback = function()
			for buf in pairs(buffers) do
				schedule(buf, 0)
			end
		end,
	})
	api.nvim_create_autocmd("OptionSet", {
		group = group,
		pattern = "background",
		callback = function()
			for buf in pairs(buffers) do
				schedule(buf, 0)
			end
		end,
	})
	api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			generation = generation + 1

			for _, job in pairs(jobs) do
				if job.process and job.state == "running" then
					job.process:kill(15)
				end
			end
		end,
	})

	for _, buf in ipairs(api.nvim_list_bufs()) do
		if api.nvim_buf_is_loaded(buf) then
			attach(buf)
		end
	end
end

return M
