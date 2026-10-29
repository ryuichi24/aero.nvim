-- One disposable dashboard subscription lifetime, independent of window ownership.
local M = {}

function M.attach(callbacks)
	local events = require("aero.events")
	local disposers = {}
	local active, pending, reload = true, false, false

	local function invalidate(needs_reload)
		reload = reload or needs_reload == true

		if not active or pending then
			return
		end

		pending = true
		vim.schedule(function()
			pending = false

			if not active then
				return
			end

			local load = reload
			reload = false

			if load then
				callbacks.load()
			end

			callbacks.render()
		end)
	end

	table.insert(
		disposers,
		require("aero.session").on_change(function()
			if callbacks.visible() then
				invalidate()
			end
		end)
	)

	for _, name in ipairs({
		"reports_changed",
		"reading_changed",
		"reference_changed",
		"repositories_changed",
		"tasks_view_changed",
	}) do
		table.insert(
			disposers,
			events.on(name, function()
				invalidate()
			end)
		)
	end

	table.insert(
		disposers,
		events.on("workspace_added", function()
			invalidate(true)
		end)
	)
	local group = vim.api.nvim_create_augroup("Aero.dashboard.subscriptions", { clear = true })
	vim.api.nvim_create_autocmd("User", {
		group = group,
		pattern = "AeroTaskChanged",
		callback = function()
			invalidate()
		end,
	})
	table.insert(disposers, require("aero.spinner").on_frame(callbacks.animate))
	return function()
		active = false

		for _, dispose in ipairs(disposers) do
			dispose()
		end

		pcall(vim.api.nvim_del_augroup_by_id, group)
	end,
		invalidate
end

return M
