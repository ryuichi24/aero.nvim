-- Run: nvim --headless -u NONE -l tests/terminal_history.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local history = require("aero.terminal_history")
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
local cwd = root .. "/space 'quote\" 日本"
vim.fn.mkdir(cwd, "p")
vim.env.HOME = root
vim.env.ZDOTDIR = root
vim.fn.writefile({ "trap ':' DEBUG", "PROMPT_COMMAND=':'" }, root .. "/.bashrc")
vim.fn.writefile({ "precmd() { return 0; }" }, root .. "/.zshrc")
local stdpath = vim.fn.stdpath
vim.fn.stdpath = function(kind) return kind == "data" and root .. "/data" or stdpath(kind) end
local ok, err = xpcall(function()
	for _, shell in ipairs({ "bash", "zsh", "/bin/bash" }) do
		if vim.fn.executable(shell) == 1 then
			local worktree = root .. "/" .. shell
			local cmd, env = history.prepare(worktree, { shell })
			local job = vim.fn.jobstart(cmd, { pty = true, env = env, cwd = cwd })
			assert(job > 0)
			-- Wait for shell configuration before submitting input.
			vim.wait(1000, function() return false end)
			vim.api.nvim_chan_send(job, "echo aero_history_test\r")
			assert(
				vim.wait(5000, function()
					local entries = history.list(worktree)
					return entries[1] and entries[1].command == "echo aero_history_test" and entries[1].exit_code == 0
				end, 20),
				shell .. ": command not captured: " .. vim.inspect(history.list(worktree))
			)
			vim.api.nvim_chan_send(job, "echo aero_history_test\r")
			assert(vim.wait(5000, function() return #history.list(worktree) == 2 end, 20), shell .. ": duplicate lost")
			vim.api.nvim_chan_send(job, "printf '%s\\n' 'first\nsecond'\r")
			assert(vim.wait(5000, function() return #history.list(worktree) == 3 end, 20), shell .. ": multiline lost")
			assert(
				history.list(worktree)[3].command == "printf '%s\\n' 'first\nsecond'",
				shell .. ": multiline changed: " .. vim.inspect(history.list(worktree))
			)
			assert(vim.wait(5000, function() return history.list(worktree)[3].exit_code == 0 end, 20))
			local entry = history.list(worktree)[3]
			assert(entry.cwd == vim.uv.fs_realpath(cwd), shell .. ": wrong working directory: " .. vim.inspect(entry))
			assert(type(entry.started_at) == "number" and entry.started_at > 0)
			assert(type(entry.duration_seconds) == "number" and entry.duration_seconds >= 0)
			vim.api.nvim_chan_send(job, "sleep 1.1; false\r")
			assert(vim.wait(5000, function() return #history.list(worktree) == 4 end, 5))
			assert(history.list(worktree)[4].exit_code == nil, "running command reported a completed status")
			assert(
				vim.wait(5000, function()
					local failed = history.list(worktree)[4]
					return failed and failed.exit_code == 1 and failed.duration_seconds >= 1
				end, 20),
				shell .. ": failure status or duration missing: " .. vim.inspect(history.list(worktree))
			)
			vim.fn.jobstop(job)
			history.prepare(worktree, { shell })
			assert(#history.list(worktree) == 4, "restarting lost commands")
			history.delete(worktree)
			assert(#history.list(worktree) == 4, "cleanup removed persistent history")
			-- A fresh module has no in-memory session state, as after restarting Neovim.
			package.loaded["aero.terminal_history"] = nil
			history = require("aero.terminal_history")
			assert(#history.list(worktree) == 4, "fresh session lost saved commands")
			local code = string.format(
				[[vim.opt.rtp:prepend(%q); vim.fn.stdpath = function() return %q end; local commands = require("aero.terminal_history").list(%q); if #commands ~= 4 or commands[3].command ~= %q then vim.cmd.cquit() else vim.cmd.qa() end]],
				vim.fn.getcwd(),
				root .. "/data",
				worktree,
				"printf '%s\\n' 'first\nsecond'"
			)
			local child = vim.system(
				{ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "lua " .. code },
				{ text = true }
			):wait(5000)
			assert(child.code == 0, "separate Neovim could not restore history: " .. (child.stderr or ""))
			assert(#history.list(root .. "/other") == 0, "history leaked between worktrees")
		end
	end
	local legacy_worktree = root .. "/legacy"
	local directory = history.directory(legacy_worktree)
	vim.fn.mkdir(directory, "p")
	local legacy = assert(io.open(directory .. "/commands", "wb"))
	legacy:write("git status\0printf 'first\nsecond'\0")
	legacy:close()
	assert(#history.list(legacy_worktree) == 2, "legacy history lost")
	assert(history.list(legacy_worktree)[2].command == "printf 'first\nsecond'")
	assert(history.list(legacy_worktree)[1].started_at == nil, "invented legacy metadata")
	vim.fn.writefile(
		{ '{"id":"new","command":"false","exit_code":1}', "broken partial JSON" },
		directory .. "/commands.jsonl"
	)
	assert(#history.list(legacy_worktree) == 3, "could not read mixed legacy/JSON history")
	assert(history.list(legacy_worktree)[3].exit_code == 1)
	-- Exercise the real terminal picker: rerun after the shell has changed directory.
	for _, shell in ipairs({ "bash", "zsh" }) do
		if vim.fn.executable(shell) == 1 then
			local terminal = require("aero.terminal")
			local worktree = root .. "/rerun-" .. shell
			vim.fn.mkdir(worktree, "p")
			vim.t.aero_worktree = worktree
			require("aero.config").options.terminal.cmd = { shell }
			local win = terminal.open(worktree, vim.api.nvim_get_current_win())
			local job = vim.b[vim.api.nvim_win_get_buf(win)].terminal_job_id
			vim.wait(1000, function() return false end)
			local function send(command, count)
				vim.api.nvim_chan_send(job, command .. "\r")
				assert(
					vim.wait(5000, function()
						local entry = history.list(worktree)[count]
						return entry and entry.exit_code == 0
					end, 20),
					"terminal command failed: " .. command
				)
			end
			send("cd -- " .. vim.fn.shellescape(cwd), 1)
			local output = root .. "/rerun-output"
			send("pwd > " .. vim.fn.shellescape(output), 2)
			vim.fn.delete(output)
			send("cd -- " .. vim.fn.shellescape(root), 3)
			local picker = require("aero.picker")
			local open = picker.open
			local selected
			picker.open = function(opts)
				selected = opts
				assert(opts.label(opts.items()[2]):find("✓", 1, true), "picker omitted command status")
			end
			terminal.history()
			picker.open = open
			selected.select(selected.items()[2])
			vim.wait(200, function() return false end)
			assert(vim.fn.filereadable(output) == 0, "paste executed the command")
			send("", 4)
			assert(
				vim.uv.fs_realpath(vim.fn.readfile(output)[1]) == vim.uv.fs_realpath(root),
				"paste changed directory"
			)
			vim.fn.delete(output)
			selected.actions.r(selected.items()[2])
			vim.wait(200, function() return false end)
			assert(vim.fn.filereadable(output) == 0, "replay paste executed the command")
			vim.api.nvim_chan_send(job, "\r")
			assert(
				vim.wait(5000, function() return vim.fn.filereadable(output) == 1 end, 20),
				"rerun produced no output"
			)
			assert(
				vim.wait(5000, function()
					local path = vim.fn.readfile(output)[1]
					return path and vim.uv.fs_realpath(path) == vim.uv.fs_realpath(cwd)
				end, 20),
				"rerun used the wrong directory: " .. vim.inspect(vim.fn.readfile(output))
			)
			vim.fn.delete(output)
			terminal.hide()
			terminal.delete(worktree)
		end
	end
end, debug.traceback)
vim.fn.delete(root, "rf")
if not ok then error(err) end
print("terminal history: ok")
