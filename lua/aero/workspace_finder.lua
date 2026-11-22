-- Workspace registration shares the reference finder's folder navigation.
local M = {}

function M.create(directory, name)
	if name == "" or name == "." or name == ".." or name:find("[/\\%c]") then
		return nil, "Git folder name must be a single directory name"
	end

	local path = vim.fs.joinpath(directory, name)

	if vim.uv.fs_lstat(path) then
		return nil, "Folder already exists: " .. path
	end

	local ok, err = vim.uv.fs_mkdir(path, 493)

	if not ok then
		return nil, err
	end

	local result = vim.system({ "git", "init", "--", path }, { text = true }):wait()

	if result.code ~= 0 then
		vim.uv.fs_rmdir(path)
		return nil, result.stderr
	end

	return path
end

function M.open(select)
	vim.api.nvim_set_hl(0, "AeroWorkspaceGitFolder", { default = true, link = "Special" })
	return require("aero.file_finder").open({
		home = require("aero.config").options.workspace_finder.home,
		target_key = "workspace",
		target_label = "Add workspace",
		title = "Workspace explorer",
		stack_title = "Workspace actions",
		filetype = "aero_workspace_finder",
		select = select,
		create = M.create,
		rename = function(old, new)
			return vim.uv.fs_rename(old, new)
		end,
		highlight = function(path)
			if vim.uv.fs_stat(vim.fs.joinpath(path, ".git")) then
				return "AeroWorkspaceGitFolder"
			end
		end,
	})
end

return M
