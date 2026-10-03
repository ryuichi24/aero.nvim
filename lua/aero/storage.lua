-- Shared storage naming: stable canonical paths and readable, collision-resistant folders.
local M = {}

function M.canonical(path)
	return vim.fs.normalize(vim.fn.resolve(vim.fn.fnamemodify(path, ":p")))
end

function M.folder(path)
	return vim.fs.basename(path):gsub("[^%w._-]", "-") .. "-" .. vim.fn.sha256(path):sub(1, 8)
end

function M.inside(path, directory)
	path, directory = M.canonical(path), M.canonical(directory)
	return vim.startswith(path, directory .. "/")
end

return M
