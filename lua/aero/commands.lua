-- Non-dashboard session commands. Selection and window policy have separate owners.
local config = require("aero.config")
local session = require("aero.session")
local panel = require("aero.panel")
local target = require("aero.session_target")
local M = {}

local function notify(message, level)
	vim.notify("Aero: " .. message, level or vim.log.levels.INFO)
end

function M.cancel()
	local selected = target.resolve("cancel")
	if not selected or not selected.chat or not selected.chat:alive() then
		notify("select a running ACP session in the dashboard or focus its panel first", vim.log.levels.WARN)
		return
	end
	selected.chat:cancel()
	return selected
end

function M.resume(session_id)
	if type(session_id) ~= "string" or vim.trim(session_id) == "" then
		notify("use :Aero resume <session-id>", vim.log.levels.WARN)
		return
	end
	local selected = target.resolve("resume")
	local agent = selected and config.options.agents[selected.agent]
	if not agent or agent.type ~= "acp" then
		notify("select an ACP session in the dashboard or focus its panel first", vim.log.levels.WARN)
		return
	end
	local win = session.prepare_win(panel.win() or require("aero.navigation").code_window())
	if session.start(selected, win, true, vim.trim(session_id)) then
		panel.shown(selected)
		vim.api.nvim_set_current_win(win)
	end
	return selected
end

function M.usage()
	local selected = target.resolve("viewed")
	if not selected then
		notify("select an agent session in the dashboard or focus its panel first", vim.log.levels.WARN)
		return
	end
	local usage = require("aero.acp.usage")
	local data = selected.chat and selected.chat.usage
	if not selected.chat then
		local saved = require("aero.history").load(selected)
		local restored = {}
		usage.restore(restored, saved and saved.usage)
		data = restored.usage
	end
	notify("Usage for " .. selected.name .. "\n" .. table.concat(usage.lines({ usage = data }), "\n"))
	return data and vim.deepcopy(data) or nil
end

return M
