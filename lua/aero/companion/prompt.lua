-- Companion prompt capability after dispatch validates epoch, identity and receipts.
local M = {}

function M.send(chat, selected, text, worktrees, finish)
	if type(text) ~= "string" or vim.trim(text) == "" or #text > 65536 then
		return finish(nil, "prompt must contain 1-65536 bytes")
	end

	local control = false

	if vim.trim(text):match("^/") then
		local command, rest = vim.trim(text):match("^([^\n]+)\n?(.*)$")
		local name, argument = vim.trim(text):match("^/(%S+)%s*(.*)$")

		if name == "context" then
			name = "reference"
			command = command:gsub("^/context", "/reference")
		end

		if name == "cancel" then
			if argument ~= "" then
				return finish(nil, "use /cancel without arguments")
			end

			finish({ status = "unknown" })
			chat:cancel()
			return finish({ status = "accepted" })
		elseif name == "model" or name == "mode" then
			local selector = require("aero.acp." .. name .. "s")

			if argument == "" or text:find("[\r\n]") then
				return finish(nil, "choose an available " .. name .. " in the companion")
			end

			local choice = selector.resolve(chat, argument)

			if not choice then
				return finish(nil, "unknown or ambiguous " .. name .. ": " .. argument)
			end

			text, control = "/" .. name .. " " .. choice.id, true
		elseif name == "new-ticket" then
			local expanded, err = require("aero.tasks.agent").expand_new_ticket(selected, text)

			if not expanded then
				return finish(nil, "Assign a board in the companion before using /new-ticket. " .. err)
			end

			text = expanded
		elseif name == "export" then
			return finish(nil, "use /export or /export readable")
		elseif name == "prompt" then
			return finish(nil, "choose a prompt snippet in the companion before sending")
		elseif name ~= "report" and name ~= "reference" then
			local advertised = false

			for _, available in ipairs(chat.commands or {}) do
				if available.name == name then
					advertised = true
					break
				end
			end

			if not advertised then
				return finish(nil, "unknown slash command: /" .. name)
			end

			control = true
		end

		if name == "reference" then
			local relative = command:match("^/reference%s+select%s+(.+)$")
			local entry, err = require("aero.companion.reference").entry(selected.worktree, relative)

			if not entry then
				return finish(nil, err or "use /reference select <path>")
			end

			text = "Read this reference "
				.. (entry.kind == "directory" and "folder" or "file")
				.. ": "
				.. vim.json.encode(entry.path)

			if rest ~= "" then
				text = text .. "\n\n" .. rest
			end
		elseif name == "report" then
			local action, report_name = command:match("^/report%s+(%S+)%s+(.+)$")

			if action ~= "new" and action ~= "select" then
				return finish(nil, "use /report new <name> or /report select <filename>")
			end

			local reports = require("aero.reports")
			local workspace

			for _, tree in ipairs(worktrees()) do
				if tree.path == selected.worktree then
					workspace = { root = tree.workspace }
					break
				end
			end

			local report, err

			if action == "new" then
				report, err = reports.create_file(selected.worktree, workspace, report_name, "")
			else
				local choices
				choices, err = reports.list(selected.worktree, workspace)

				for _, choice in ipairs(choices) do
					if choice.name == report_name then
						report = choice
						break
					end
				end
			end

			if not report then
				return finish(nil, err or "report unavailable")
			end

			text = require("aero.config").options.reports.prompt:gsub("{path}", function()
				return vim.json.encode(report.path)
			end)

			if rest ~= "" then
				text = text .. "\n\n" .. rest
			end
		end
	end

	local queued = chat.state ~= "ready" or chat.busy or chat.model_pending or chat.mode_pending or chat.task_pending
	finish({ status = "unknown" })
	local binding = selected.task_binding

	if binding and not binding.revoked and not control then
		text = table.concat({
			"Current Aero assignment: workspace "
				.. vim.json.encode(binding.workspace.root)
				.. ", board "
				.. vim.json.encode(binding.board_id)
				.. ".",
			binding.ticket_id and ("Assigned ticket: " .. vim.json.encode(binding.ticket_id) .. ".")
				or "Board-only assignment: no ticket is assigned. Read the board and create tickets through Aero MCP tools when requested; do not implement them unless asked.",
			"Use the current assignment rather than any superseded assignment in this conversation. Do not write task documents directly.",
			"",
			text,
		}, "\n")
	end

	chat:prompt(text)
	return finish({ status = queued and "queued" or "accepted" })
end

return M
