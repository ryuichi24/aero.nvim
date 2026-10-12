vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero").setup({ state_file = root .. "/state.json" })
local install = require("aero.tasks.install")
local storage = require("aero.tasks.storage")
local read, system, stdpath = storage.read, vim.system, vim.fn.stdpath
storage.read = function(file)
	local text, read_err = read(file)
	if file:match("/release.json$") and text then
		local manifest = vim.json.decode(text)
		manifest.published = false
		return vim.json.encode(manifest)
	end
	return text, read_err
end
local path, err = install.resolve()
assert(not path and err:find("development revision", 1, true))
local config = require("aero.config").options.tasks.agent
config.executable = root .. "/missing"
path, err = install.resolve()
assert(not path and err:find("not executable", 1, true))
if vim.env.AERO_MCP_EXECUTABLE then
	config.executable = vim.env.AERO_MCP_EXECUTABLE
	assert(install.resolve())
end
assert(install.platform())
-- Published installation uses exact assets and hashes binary bytes, including NUL.
local binary = "fake\0standalone\255binary"
local version = "9.8.7-fixture"
local asset = "aero-mcp-" .. version .. "-" .. install.platform()
storage.read = function(file)
	if file:match("/release.json$") then
		return vim.json.encode({ version = version, bridge_protocol = 1, published = true })
	end
	return read(file)
end
vim.fn.stdpath = function(kind)
	return kind == "data" and root .. "/data" or stdpath(kind)
end
local mismatch = false
local executable_version = version
local downloads = 0
local windows = #vim.api.nvim_list_wins()
vim.system = function(cmd, opts, callback)
	local function completed(result)
		vim.schedule(function()
			callback(result)
		end)
		return {
			wait = function()
				return result
			end,
		}
	end
	if cmd[1] == "curl" then
		local win
		for _, candidate in ipairs(vim.api.nvim_list_wins()) do
			if vim.api.nvim_win_get_config(candidate).title then
				win = candidate
			end
		end
		assert(win, "tasks download has no progress popup")
		opts.stderr(nil, "######## 65.0%\r")
		vim.schedule(function()
			local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)
			assert(lines[1]:find("65.0% downloaded", 1, true), "tasks download percentage missing")
			assert(lines[2] == asset)
		end)
		downloads = downloads + 1
		local target, url = cmd[#cmd - 1], cmd[#cmd]
		assert(url:find("/v" .. version .. "/", 1, true), "installer selected an unrelated version")
		local file = assert(io.open(target, "wb"))
		if url:match("SHA256SUMS$") then
			local hash = string.rep("0", 64)
			file:write(hash .. "  " .. asset .. "\n")
		else
			file:write(binary)
		end
		file:close()
		return completed({ code = 0, stdout = "", stderr = "" })
	elseif cmd[1] == "sha256sum" or cmd[1] == "shasum" then
		assert(read(cmd[#cmd]) == binary, "binary bytes changed in download")
		return completed({ code = 0, stdout = string.rep(mismatch and "1" or "0", 64) .. "  " .. cmd[#cmd] })
	elseif cmd[2] == "--version" then
		return completed({ code = 0, stdout = vim.json.encode({ version = executable_version, bridge_protocol = 1 }) })
	end
	return system(cmd, opts, callback)
end
config.executable = false
local installed = assert(install.install())
assert(#vim.api.nvim_list_wins() == windows, "tasks installation left popup open")
assert(read(installed) == binary)
assert(vim.uv.fs_stat(installed).mode % 512 == 493)
mismatch = true
local failed, checksum_err = install.install()
assert(not failed and checksum_err:find("checksum", 1, true))
assert(#vim.api.nvim_list_wins() == windows, "failed tasks installation left popup open")
assert(read(installed) == binary, "failed installation replaced the existing executable")
mismatch = false
executable_version = "0.1.0"
local original_stat = vim.uv.fs_stat(installed)
failed, err = install.install()
assert(not failed and err:find("got 0.1.0", 1, true))
assert(vim.uv.fs_stat(installed).ino == original_stat.ino, "wrong-version download replaced the executable")
config.executable = installed
local before = downloads
failed, err = install.install()
assert(not failed and err:find(installed, 1, true) and err:find("tasks.agent.executable", 1, true))
assert(downloads == before, "custom executable must not be overwritten")
config.executable = ""
executable_version = version
assert(install.install(), "empty executable should use release installation")
storage.read, vim.system, vim.fn.stdpath = read, system, stdpath
vim.fn.delete(root, "rf")
print("Task executable resolution tests passed.")
vim.cmd("qa!")
