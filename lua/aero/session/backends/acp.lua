-- Session ownership adapter for ACP conversations; protocol and editor state stay in aero.acp.
local M = {}

function M.start(s, buf, agent, resume, session_id, opts)
	s.buf, s.job, s.exit_code, s.fresh = buf, nil, nil, false
	s.chat = require("aero.acp").start(s, buf, agent, resume, session_id, opts)

	if not s.chat then
		s.buf = nil
		vim.api.nvim_buf_delete(buf, { force = true })
		return false
	end

	return true
end

function M.stop(s)
	if s.chat then
		s.chat:stop()
	end
end

function M.forget(s)
	require("aero.acp").forget(s)
end

return M
