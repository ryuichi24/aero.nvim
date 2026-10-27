-- Map unified diff change blocks onto the full-file code preview.
local M = {}

function M.render(buf, namespace, output, deleted)
	local count = vim.api.nvim_buf_line_count(buf)

	local function mark(line, kind)
		vim.api.nvim_buf_set_extmark(buf, namespace, math.max(0, math.min(line - 1, count - 1)), 0, {
			sign_text = ({ Add = "+", Change = "~", Delete = "_" })[kind],
			sign_hl_group = "AeroReview" .. kind,
			priority = kind == "Delete" and 201 or 200,
		})
	end

	local old_line, new_line, start, removed, added

	local function flush()
		if not start then
			return
		end

		if deleted then
			for line = old_line - removed, old_line - 1 do
				mark(line, "Delete")
			end
		else
			for i = 0, added - 1 do
				mark(start + i, i < removed and "Change" or "Add")
			end

			if removed > added then
				mark(start + added - 1, "Delete")
			end
		end

		start, removed, added = nil, 0, 0
	end

	for text in (output .. "\n"):gmatch("([^\n]*)\n") do
		local old, new = text:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")

		if old then
			flush()
			old_line, new_line = tonumber(old), tonumber(new)
		elseif new_line then
			local prefix = text:sub(1, 1)

			if prefix == "-" or prefix == "+" then
				if not start then
					start, removed, added = new_line, 0, 0
				end

				if prefix == "-" then
					removed, old_line = removed + 1, old_line + 1
				else
					added, new_line = added + 1, new_line + 1
				end
			elseif prefix ~= "\\" then
				flush()

				if prefix == " " then
					old_line, new_line = old_line + 1, new_line + 1
				else
					old_line, new_line = nil, nil
				end
			end
		end
	end

	flush()
end

return M
