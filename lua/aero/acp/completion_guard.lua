-- Aero owns suggestions in its draft buffers; keep code-buffer completion intact.
local M = {}
local api = vim.api

function M.apply(buf)
	if not api.nvim_buf_is_valid(buf) then return end
	-- Respected by blink.cmp, mini.completion, and coc.nvim respectively.
	vim.b[buf].completion = false
	vim.b[buf].minicompletion_disable = true
	vim.b[buf].coc_suggest_disable = 1
	local cmp = package.loaded["cmp"]
	if cmp and cmp.setup and cmp.setup.buffer then
		api.nvim_buf_call(buf, function() cmp.setup.buffer({ enabled = false }) end)
		if api.nvim_get_current_buf() == buf and cmp.abort then cmp.abort() end
	end
	local blink = package.loaded["blink.cmp"]
	if blink and blink.hide and api.nvim_get_current_buf() == buf then blink.hide() end
	if vim.lsp.completion and vim.lsp.completion.enable then
		for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
			vim.lsp.completion.enable(false, client.id, buf)
		end
	end
end

return M
