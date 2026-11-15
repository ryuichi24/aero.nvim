-- Cross-board recovery is one workspace-locked operation, including copy/commit/cleanup.
local storage = require("aero.tasks.storage")
local markdown = require("aero.tasks.markdown")
return function(mutable, save, entry, read_ticket)
	return function(ws, source_path, ticket_path, target_path, state_name, options)
		return storage.with_lock(ws, function()
			local source, err = mutable(ws, source_path)

			if not source then
				return nil, err
			end

			local target

			if source.path == require("aero.storage").canonical(target_path) then
				target = source
			else
				target, err = mutable(ws, target_path)
			end

			if not target then
				return nil, err
			end

			if options and options.guard then
				local allowed, guard_err = options.guard(source, target)

				if not allowed then
					return nil, guard_err
				end
			end

			local ticket, ticket_err = read_ticket(source.path, ticket_path)

			if not ticket or not ticket.valid then
				return nil, ticket_err or "invalid removed ticket"
			end

			if options and options.expected_ticket_id and ticket.metadata.id ~= options.expected_ticket_id then
				return nil, "removed ticket identity changed; reload the list"
			end

			if entry(source, ticket.path) then
				return nil, "ticket is no longer removed; reload the list"
			end

			for _, state in ipairs(source.states) do
				for _, item in ipairs(state.entries) do
					if item.ticket and item.ticket.metadata and item.ticket.metadata.id == ticket.metadata.id then
						return nil, "removed ticket identity conflicts with a referenced ticket"
					end
				end
			end

			local found = 0

			for _, orphan in ipairs(source.orphans) do
				if orphan.ticket and orphan.ticket.metadata and orphan.ticket.metadata.id == ticket.metadata.id then
					found = found + 1
				end
			end

			if found ~= 1 then
				return nil, "removed ticket identity is missing or ambiguous"
			end

			local state = markdown.state(target, state_name)

			if not state then
				return nil, "unknown recovery state"
			end

			local destination = ticket.path

			if target ~= source then
				for _, target_state in ipairs(target.states) do
					for _, item in ipairs(target_state.entries) do
						if item.ticket and item.ticket.metadata and item.ticket.metadata.id == ticket.metadata.id then
							return nil, "destination board already contains this ticket ID"
						end
					end
				end

				for _, orphan in ipairs(target.orphans) do
					if orphan.ticket and orphan.ticket.metadata and orphan.ticket.metadata.id == ticket.metadata.id then
						return nil, "destination board already has a removed ticket with this ID"
					end
				end

				local path_err
				destination, path_err = storage.ticket_path(target.path, "tickets/" .. vim.fs.basename(ticket.path))

				if not destination then
					return nil, path_err
				end
			end

			local ok, buffer_err = storage.unmodified(ticket.path)

			if not ok then
				return nil, buffer_err
			end

			local source_buf, target_buf = vim.fn.bufnr(ticket.path), vim.fn.bufnr(destination)

			if destination ~= ticket.path and source_buf > 0 and target_buf > 0 then
				return nil, "destination ticket path already has an editor buffer; close it before transferring"
			end

			if destination ~= ticket.path then
				vim.fn.mkdir(vim.fs.dirname(destination), "p")
				ok, err = storage.create(destination, ticket.text)

				if not ok then
					return nil, "could not create recovery copy at " .. destination .. ": " .. tostring(err)
				end

				local stat = vim.uv.fs_stat(ticket.path)

				if stat then
					ok, err = vim.uv.fs_chmod(destination, stat.mode % 512)

					if not ok then
						local cleaned = storage.read(target.path) == target.text
							and storage.read(destination) == ticket.text
							and storage.unmodified(destination)
							and vim.uv.fs_unlink(destination)
						return nil,
							"could not preserve ticket permissions: "
								.. tostring(err)
								.. (not cleaned and "; retained recovery copy: " .. destination or "")
					end
				end
			end

			local placed = { path = destination, metadata = ticket.metadata }
			ok, err = save(target, markdown.insert(target.lines, state, markdown.entry(placed)))

			if not ok then
				if destination ~= ticket.path then
					if
						storage.read(target.path) == target.text
						and storage.read(destination) == ticket.text
						and storage.unmodified(destination)
					then
						if not vim.uv.fs_unlink(destination) then
							err = tostring(err) .. "; retained recovery copy: " .. destination
						end
					else
						err = tostring(err) .. "; retained recovery copy: " .. destination
					end
				end

				return nil, err
			end

			local warning

			if destination ~= ticket.path then
				if
					storage.read(source.path) ~= source.text
					or storage.read(ticket.path) ~= ticket.text
					or not storage.unmodified(ticket.path)
				then
					warning = "recovered ticket, but the changed source was retained at " .. ticket.path
				else
					local deleted, unlink_err = vim.uv.fs_unlink(ticket.path)

					if not deleted then
						warning = "recovered ticket, but retained its old file at "
							.. ticket.path
							.. ": "
							.. tostring(unlink_err)
					elseif source_buf > 0 and vim.api.nvim_buf_is_valid(source_buf) then
						local renamed, rename_err = pcall(vim.api.nvim_buf_set_name, source_buf, destination)

						if not renamed then
							warning = "ticket transferred; editor buffer rename failed: " .. tostring(rename_err)
						else
							local refreshed, refresh_err = pcall(storage.refresh, destination)

							if not refreshed then
								warning = "ticket transferred; editor buffer refresh failed: " .. tostring(refresh_err)
							end
						end
					end
				end
			end

			return { path = destination, board_path = target.path, warning = warning }
		end)
	end
end
