local M = {}

function M.check()
	vim.health.start("aero")
	if vim.fn.has("nvim-0.11") == 1 then
		vim.health.ok("Neovim " .. tostring(vim.version()))
	else
		vim.health.error("Neovim 0.11+ is required")
	end
	if vim.fn.executable("git") == 1 then
		vim.health.ok("git found")
	else
		vim.health.error("git not found")
	end
	local version, yq_err = require("aero.tasks.frontmatter").check_yq()
	if version then
		vim.health.ok("Task YAML parser: " .. version)
	else
		vim.health.warn(yq_err)
	end
	for name, agent in pairs(require("aero.config").options.agents) do
		local cmd = type(agent.cmd) == "table" and agent.cmd[1]
		if not cmd then
			vim.health.info(name .. ": command is a function, not checked")
		elseif vim.fn.executable(cmd) == 1 then
			vim.health.ok(name .. ": " .. cmd .. " found")
		else
			vim.health.warn(name .. ": " .. cmd .. " not executable")
		end
	end
	vim.health.start("Aero task MCP server")
	if require("aero.config").options.tasks.agent.enabled then
		local executable, err = require("aero.tasks.install").resolve()
		if executable then
			vim.health.ok("aero-mcp: " .. executable .. " (executable and version compatibility verified)")
		else
			vim.health.error(err)
		end
	else
		vim.health.info("aero-mcp: disabled; enable tasks.agent.enabled to use task-agent integration")
	end
end

return M
