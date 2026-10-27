-- Fold construction must not make a highlighter visit the entire history.
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local folds = require("aero.acp.folds")
local buf = api.nvim_get_current_buf()
api.nvim_buf_set_lines(buf, 0, -1, false, { "turn", "tool", "output", "output", "end", "tail" })
local chat = {
	buf = buf,
	sections = {
		{ kind = "turn", key = {}, first = 1, last = 5, closed = false },
		{ kind = "tool", key = {}, first = 2, last = 4, closed = true },
	},
}
local active = vim.treesitter.highlighter.active
local original_stop, original_start = vim.treesitter.stop, vim.treesitter.start
local original_cursor = api.nvim_win_set_cursor
local stops, starts, highlighted_moves = 0, 0, 0
local highlighter = { tree = {
	lang = function()
		return "markdown"
	end,
} }
active[buf] = highlighter
vim.treesitter.stop = function(target)
	assert(target == buf)

	stops = stops + 1
	active[buf] = nil
end
vim.treesitter.start = function(target, language)
	assert(target == buf and language == "markdown", "original highlighting language must be restored")

	starts = starts + 1
	active[buf] = highlighter
end
local fail = false
api.nvim_win_set_cursor = function(...)
	if active[buf] then
		highlighted_moves = highlighted_moves + 1
	end

	if fail then
		error("fold initialization failed")
	end

	return original_cursor(...)
end
folds.apply(chat)

assert(stops == 1 and starts == 1 and active[buf] == highlighter)
assert(highlighted_moves == 0, "initial fold setup must not highlight historical cursor locations")
assert(vim.fn.foldclosed(2) == 2 and vim.fn.foldclosedend(2) == 4, "default folds must still be correct")

folds.apply(chat)

assert(stops == 1 and starts == 1, "ordinary renders must not restart highlighting")

chat.fold_views = nil
fail = true
local ok, err = pcall(folds.apply, chat)

assert(not ok and err:find("fold initialization failed", 1, true))
assert(stops == 2 and starts == 2 and active[buf] == highlighter, "highlighting must resume after fold errors")

fail = false
active[buf] = nil
chat.fold_views = nil
folds.apply(chat)

assert(starts == 2 and stops == 2, "disabled highlighting must stay disabled")

api.nvim_win_set_cursor = original_cursor
vim.treesitter.stop, vim.treesitter.start = original_stop, original_start
print("Cold transcript folding passed (no historical highlighting, fold state, error recovery, disabled highlighting)")
vim.cmd.qa({ bang = true })
