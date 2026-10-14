-- Placement commit: validate all ticket edits before writing, then update the board.
-- A failed write restores prior ticket state without overwriting newer revisions.
local storage = require("aero.tasks.storage")
local markdown = require("aero.tasks.markdown")
local fm = require("aero.tasks.frontmatter")
local documents = require("aero.tasks.documents")
local query = require("aero.tasks.query")
local M = {}

function M.placements(doc, lines)
	local changed = fm.edit(lines, doc.frontmatter, { updated_at = documents.now() })
	local text = storage.text(changed, doc.text)
	local edits, written = {}, {}
	local board = markdown.parse(text, "board", doc.path)
	for _, state in ipairs(board.states) do
		for _, item in ipairs(state.entries) do
			local ticket, err = query.read_ticket(doc.path, item.path)
			if not ticket or not ticket.valid then
				return nil, err or "invalid ticket metadata"
			end
			if ticket.metadata.state ~= state.name then
				local ok, buffer_err = storage.unmodified(ticket.path)
				if not ok then
					return nil, buffer_err
				end
				local updated =
					fm.edit(ticket.lines, ticket.frontmatter, { state = state.name, updated_at = documents.now() })
				table.insert(
					edits,
					{ path = ticket.path, original = ticket.text, text = storage.text(updated, ticket.text) }
				)
			end
		end
	end
	local function rollback(err)
		for index = #written, 1, -1 do
			local edit = written[index]
			local ok, restore_err = storage.write(edit.path, edit.text, edit.original)
			if not ok then
				err = tostring(err)
					.. "; ticket state rollback failed at "
					.. edit.path
					.. ": "
					.. tostring(restore_err)
			end
		end
		return nil, err
	end
	for _, edit in ipairs(edits) do
		local ok, err = storage.write(edit.path, edit.original, edit.text)
		if not ok then
			return rollback(err)
		end
		table.insert(written, edit)
	end
	local ok, err = storage.write(doc.path, doc.text, text)
	if not ok then
		return rollback(err)
	end
	return true
end

return M
