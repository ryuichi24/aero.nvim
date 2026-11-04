local api = vim.api
local M = { installation_url = "https://github.com/zenbu-labs/terminal-browser#installation" }
local buffers = {}

function M.check(capabilities)
	local command = require("aero.config").options.browser.cmd
	local platform = vim.uv.os_uname().sysname
	local install = (platform == "Darwin" or vim.fn.executable("brew") == 1) and "brew install terminal-browser"
		or "curl -fsSL https://terminal-browser.sh/install | bash"
	local guidance = {
		dependency = "terminal-browser",
		installation_url = M.installation_url,
		suggested_command = install,
		next_step = "Ask the user to install terminal-browser and run terminal-browser setup in an external terminal, then retry. Configure browser.cmd with an absolute path if Neovim's PATH is stale.",
	}

	if platform == "Windows_NT" then
		guidance.next_step = "Use terminal-browser inside WSL, following the upstream Windows installation instructions. "
			.. guidance.next_step
	end

	if type(command) ~= "table" or type(command[1]) ~= "string" or command[1] == "" then
		guidance.code, guidance.message = "dependency_unavailable", "browser.cmd must be a nonempty command array."
		return nil, guidance
	end

	if vim.fn.executable(command[1]) ~= 1 then
		guidance.code, guidance.message = "dependency_missing", command[1] .. " was not found on Neovim's PATH."
		return nil, guidance
	end

	local path = vim.fn.exepath(command[1])

	if not capabilities then
		return { executable = path }
	end

	local ok, result = pcall(function()
		return vim.system(vim.list_extend(vim.deepcopy(command), { "capabilities" }), { text = true, timeout = 3000 })
			:wait()
	end)
	local decoded, data = pcall(vim.json.decode, ok and result.stdout or "")

	if
		not ok
		or result.code ~= 0
		or not decoded
		or type(data) ~= "table"
		or type(data.capabilities) ~= "table"
		or not vim.tbl_contains(data.capabilities, "embedding")
	then
		guidance.code = "dependency_incompatible"
		guidance.message = "Could not verify terminal-browser embedding support at " .. path .. "."
		guidance.details = ok and vim.trim(result.stderr or "") or tostring(result)
		guidance.next_step =
			"Run terminal-browser setup in an external terminal. Upgrade terminal-browser if embedding support is unavailable, then retry."
		return nil, guidance
	end

	return { executable = path, capabilities = data.capabilities }
end

function M.show(win, worktree, failure)
	local buf = buffers[worktree]

	if not buf or not api.nvim_buf_is_valid(buf) then
		buf = api.nvim_create_buf(false, true)
		buffers[worktree] = buf
		vim.bo[buf].bufhidden = "hide"
		vim.bo[buf].filetype = "aero-browser-setup"
		vim.keymap.set("n", "R", function()
			if vim.t.aero_worktree == worktree then
				require("aero.reader").select("browser")
			end
		end, { buffer = buf, desc = "Browser: retry setup detection" })
		vim.keymap.set("n", "O", function()
			vim.ui.open(M.installation_url)
		end, { buffer = buf, desc = "Browser: installation instructions" })
	end

	local lines = {
		"Browser setup required",
		"",
		failure.message,
		"",
		"Install terminal-browser:",
		"  " .. (failure.suggested_command or "See installation instructions below."),
		"",
		"Then run in an external terminal:",
		"  terminal-browser setup",
		"",
		"[R] Retry detection    [Y] Copy install command    [O] Installation instructions",
		"",
		"No Neovim restart is required to retry.",
		"If Neovim's PATH is stale, configure an absolute executable path:",
		'  browser = { cmd = { "/path/to/terminal-browser" } }',
		"",
		M.installation_url,
	}

	if failure.next_step then
		vim.list_extend(lines, { "", failure.next_step })
	end

	if failure.details and failure.details ~= "" then
		vim.list_extend(lines, { "", "Details:", unpack(vim.split(failure.details, "\n", { plain = true })) })
	end

	vim.bo[buf].modifiable = true
	api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.keymap.set("n", "Y", function()
		vim.fn.setreg('"', failure.suggested_command or "")
		vim.fn.setreg("+", failure.suggested_command or "")
	end, { buffer = buf, desc = "Browser: copy install command" })

	if win then
		api.nvim_win_set_buf(win, buf)
		vim.wo[win].wrap = true
	end

	return buf
end

return M
