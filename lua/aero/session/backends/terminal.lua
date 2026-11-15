-- PTY transport and virtual-terminal scrollback. Session lifecycle events belong to the caller.
local history = require("aero.history")
local M = {}

function M.save(s)
	local buf = s.buf
	history.save(s, function()
		if buf and vim.api.nvim_buf_is_valid(buf) then
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

			-- Empty screen rows are not part of the saved scrollback.
			while #lines > 0 and lines[#lines] == "" do
				table.remove(lines)
			end
			return { type = "terminal", lines = lines }
		end
	end)
end

function M.flush(s)
	M.save(s)
	history.flush(s)
end

function M.cleanup(buf)
	pcall(vim.api.nvim_del_augroup_by_name, "aero.terminal." .. buf)
end

--- Launch into a prepared buffer. on_exit runs only for the session's current job.
--- On failure the new buffer is discarded; the caller retains ownership of the old one.
function M.start(s, win, resume, agent, buf, on_exit)
	local cmd = resume and agent.resume or agent.cmd

	if type(cmd) == "function" then
		cmd = cmd(s)
	end

	s.chat = nil
	local saved = resume and history.load(s)
	local term, job

	-- A virtual terminal lets us seed scrollback before connecting the new PTY.
	term = vim.api.nvim_open_term(buf, {
		on_input = function(_, _, _, data)
			if job and job > 0 and s.job == job then
				vim.fn.chansend(job, data)
			end
		end,
	})

	if saved and saved.type == "terminal" and type(saved.lines) == "table" and #saved.lines > 0 then
		vim.bo[buf].scrollback = math.min(100000, math.max(vim.bo[buf].scrollback, #saved.lines + 100))

		-- Escape control characters so a snapshot is displayed as text, not terminal commands.
		local text = table.concat(saved.lines, "\r\n"):gsub("[%z\1-\8\11\12\14-\31\127]", "")

		-- Move all restored lines off the live screen before a TUI clears/redraws it.
		vim.api.nvim_chan_send(
			term,
			text
				.. "\r\n--- restored scrollback ---"
				.. string.rep("\r\n", vim.api.nvim_win_get_height(win))
				.. "\27[H\27[2J"
		)
	end

	local ok, result = pcall(vim.api.nvim_win_call, win, function()
		return vim.fn.jobstart(cmd, {
			pty = true,
			width = vim.api.nvim_win_get_width(win),
			height = vim.api.nvim_win_get_height(win),
			cwd = s.worktree,
			env = vim.tbl_extend("force", { TERM = "xterm-256color" }, agent.env or {}, s.runtime_env or {}),
			on_stdout = function(_, data)
				if vim.api.nvim_buf_is_valid(buf) then
					vim.api.nvim_chan_send(term, table.concat(data, "\n"))
				end
			end,
			on_exit = function(id, code)
				vim.schedule(function()
					if s.job == id then
						if vim.api.nvim_buf_is_valid(buf) then
							vim.api.nvim_chan_send(term, ("\r\n[Process exited %d]\r\n"):format(code))
						end

						M.flush(s)
						s.job, s.exit_code = nil, code

						-- The virtual terminal outlives the PTY so its scrollback stays readable.
						-- It does not leave terminal input mode automatically when the job exits.
						if vim.api.nvim_get_current_buf() == buf then
							vim.cmd.stopinsert()
						end

						on_exit(code)
					end
				end)
			end,
		})
	end)
	job = result

	if not ok or job <= 0 then
		vim.api.nvim_buf_delete(buf, { force = true })
		vim.notify(
			("aero: failed to start %s: %s"):format(table.concat(cmd, " "), ok and "not executable" or job),
			vim.log.levels.ERROR
		)
		return false
	end

	s.buf, s.job, s.exit_code, s.fresh = buf, job, nil, false
	vim.b[buf].terminal_job_id = job
	vim.b[buf].terminal_job_pid = vim.fn.jobpid(job)
	s.last_output = vim.uv.now()
	vim.b[buf].aero_session = s.key
	require("aero.fullscreen").bind(buf)
	pcall(vim.api.nvim_buf_set_name, buf, ("aero://%s#%s"):format(s.worktree, s.name))
	vim.api.nvim_buf_attach(buf, false, {
		on_lines = function()
			if s.buf ~= buf then
				return true
			end

			s.last_output = vim.uv.now()
			M.save(s)
		end,
	})
	local group = vim.api.nvim_create_augroup("aero.terminal." .. buf, { clear = true })
	vim.api.nvim_create_autocmd("TermEnter", {
		group = group,
		buffer = buf,
		callback = function()
			if s.buf == buf and not s.job then
				vim.schedule(function()
					if s.buf == buf and not s.job and vim.api.nvim_get_current_buf() == buf then
						vim.cmd.stopinsert()
					end
				end)
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "VimResized", "WinResized", "BufWinEnter" }, {
		group = group,
		callback = function()
			if s.buf ~= buf or s.job ~= job then
				return
			end

			local visible = vim.fn.bufwinid(buf)

			if visible ~= -1 then
				vim.fn.jobresize(job, vim.api.nvim_win_get_width(visible), vim.api.nvim_win_get_height(visible))
			end
		end,
	})
	return true
end

function M.stop(s)
	if s.buf and not s.chat then
		M.flush(s)
	end

	if s.job then
		vim.fn.jobstop(s.job)
	end
end

return M
