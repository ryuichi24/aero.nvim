-- Ordered runtime subscriptions with explicit disposal and visible failures.
local M = {}

function M.new(label)
	local items = {}
	local registry = {}

	function registry.on(callback)
		assert(type(callback) == "function", "aero: listener must be a function")
		local item = { callback = callback, active = true }
		table.insert(items, item)
		return function()
			item.active = false
		end
	end

	function registry.emit()
		local any = false

		for _, item in ipairs(vim.list_slice(items)) do
			if item.active then
				local ok, more = xpcall(item.callback, debug.traceback)

				if ok then
					any = any or more == true
				else
					vim.schedule(function()
						vim.notify("aero: " .. label .. " listener failed: " .. tostring(more), vim.log.levels.ERROR)
					end)
				end
			end
		end

		items = vim.tbl_filter(function(item)
			return item.active
		end, items)
		return any
	end

	return registry
end

return M
