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

	vim.health.start("Aero browser (optional)")
	local browser, browser_error = require("aero.browser.setup").check(true)

	if browser then
		vim.health.ok("terminal-browser: " .. browser.executable .. " (embedding capability verified)")
		vim.health.info("Live Kitty graphics and input compatibility require a terminal smoke test.")
	else
		vim.health.warn(browser_error.message, {
			browser_error.suggested_command,
			browser_error.next_step,
			browser_error.installation_url,
		})
	end

	local failure = require("aero.browser").failure(vim.t.aero_worktree)

	if failure and (failure.code == "browser_startup_failed" or failure.code == "browser_frame_failed") then
		vim.health.warn(
			failure.message .. "\n" .. (failure.details or ""),
			{ failure.next_step or "Retry browser setup." }
		)
	end
end

return M
