-- Worktree reference imports use the shared file-selection and staging UI.
local M = {}

function M.open(worktree)
	return require("aero.file_finder").open({
		home = require("aero.config").options.reference_finder.home,
		target_key = "reference:" .. worktree,
		target_label = vim.fs.basename(worktree),
		target_path = vim.fn.fnamemodify(worktree, ":~"),
		target_kind = "Worktree",
		title = "Reference finder",
		stack_title = "Staged references",
		filetype = "aero_reference",
		transfer = function(items)
			return require("aero.reference").transfer(worktree, items)
		end,
	})
end

return M
