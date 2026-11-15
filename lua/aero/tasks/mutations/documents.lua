-- Guarded metadata/body edits retain the shared workspace lock and revision checks.
local storage = require("aero.tasks.storage")
local markdown = require("aero.tasks.markdown")
local fm = require("aero.tasks.frontmatter")
return function(context)
	local M = {}

	function M.update_metadata(ws, board_path, ticket_path, changes, options)
		return storage.with_lock(ws, function()
			local reader = options and options.guard and ticket_path and not changes.title and context.read_board
				or context.mutable
			local board, err = reader(ws, board_path)

			if not board then
				return nil, err
			end

			local doc = board

			if ticket_path then
				doc, err = context.read_ticket(board.path, ticket_path)

				if not doc then
					return nil, err
				end
			end

			if not doc.valid then
				return nil, "fix document diagnostics before editing metadata"
			end

			local allowed, guard_err = context.guarded(options, board, ticket_path, doc)

			if not allowed then
				return nil, guard_err
			end

			for _, field in ipairs({ "id", "schema_version", "aero_type", "created_at" }) do
				if changes[field] ~= nil then
					return nil, "identity field cannot be edited: " .. field
				end
			end

			if ticket_path and changes.state ~= nil then
				return nil, "ticket state is managed by board placement; move the ticket instead"
			end

			local updated = vim.tbl_extend("force", doc.metadata, changes, { updated_at = context.now() })
			local errors = fm.validate(updated, ticket_path and "ticket" or "board")

			if #errors > 0 then
				return nil, table.concat(errors, "; ")
			end

			local edits = vim.tbl_extend("force", changes, { updated_at = updated.updated_at })
			local lines = doc.lines

			if changes.title then
				lines = markdown.title(lines, doc.metadata.title, changes.title, doc.frontmatter.finish)
			end

			lines = fm.edit(lines, doc.frontmatter, edits)
			local ok, write_err = storage.write(doc.path, doc.text, storage.text(lines, doc.text))

			if not ok then
				return nil, write_err
			end

			if ticket_path and changes.title then
				local item = context.entry(board, doc.path)

				if item then
					local board_lines = vim.deepcopy(board.lines)
					local comment = item.raw:match("%s+(<!%-%-.*%-%->)%s*$")
					board_lines[item.line] = markdown.entry({ path = doc.path, metadata = updated })
						.. (comment and " " .. comment or "")
					ok, write_err = context.save(board, board_lines)

					if not ok then
						return nil, "metadata saved but board label update failed: " .. tostring(write_err)
					end
				end
			end

			return true
		end)
	end

	function M.update_body(ws, board_path, ticket_path, body, options)
		if type(body) ~= "string" or body:find("\0", 1, true) then
			return nil, { code = "INVALID_ARGUMENT", message = "body must be Markdown text without NUL bytes" }
		end

		return storage.with_lock(ws, function()
			local board, err = context.read_board(ws, board_path)

			if not board or not board.valid then
				return nil, err or { code = "INVALID_DOCUMENT", message = "invalid board" }
			end

			local ticket, ticket_err = context.read_ticket(board.path, ticket_path)

			if not ticket or not ticket.valid then
				return nil, ticket_err or { code = "INVALID_DOCUMENT", message = "invalid ticket" }
			end

			local allowed, guard_err = context.guarded(options, board, ticket_path, ticket)

			if not allowed then
				return nil, guard_err
			end

			local lines = vim.list_slice(ticket.lines, 1, ticket.frontmatter.finish)
			vim.list_extend(lines, storage.lines(body))
			lines = fm.edit(lines, ticket.frontmatter, { updated_at = context.now() })
			return storage.write(ticket.path, ticket.text, storage.text(lines, ticket.text))
		end)
	end

	return M
end
