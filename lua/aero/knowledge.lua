-- Public knowledge API; domain operations do not load interactive browsing.
local M = vim.tbl_extend("force", {}, require("aero.knowledge.catalog"))

for _, action in ipairs({ "add_files", "new_space", "browse_space", "open", "pick_sources", "command" }) do
	M[action] = function(...)
		return require("aero.knowledge.ui")[action](...)
	end
end

return M
