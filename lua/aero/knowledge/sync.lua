-- Poll connected folders without changing Neovim's current directory or buffers.
local M = {}
local timer, active, last_error

function M.stop()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

function M.run()
	if active then
		return
	end

	active = true
	local data = require("aero.knowledge.store").catalog()

	for _, space in ipairs(data and data.spaces or {}) do
		if #space.folders > 0 then
			local ok, err = pcall(require("aero.knowledge").sync_folders, space.id)

			if not ok and tostring(err) ~= last_error then
				last_error = tostring(err)
				vim.notify("Aero knowledge folder sync: " .. last_error, vim.log.levels.WARN)
			end
		end
	end

	active = false
end

function M.setup()
	M.stop()
	vim.schedule(function()
		require("aero.knowledge.ingest").recover()
	end)
	local interval = require("aero.config").options.knowledge.sync_interval

	if type(interval) == "number" and interval > 0 then
		timer = vim.uv.new_timer()
		timer:start(interval, interval, vim.schedule_wrap(M.run))
		timer:unref()
	end

	local group = vim.api.nvim_create_augroup("AeroKnowledgeSync", { clear = true })
	vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.stop })
end

return M
