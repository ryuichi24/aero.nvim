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
vim.system = function(cmd, opts, callback)
	if cmd[1] == "curl" then
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
		return {
			wait = function()
				return { code = 0, stdout = "", stderr = "" }
			end,
		}
	elseif cmd[1] == "sha256sum" or cmd[1] == "shasum" then
		assert(read(cmd[#cmd]) == binary, "binary bytes changed in download")
		return {
			wait = function()
				return { code = 0, stdout = string.rep(mismatch and "1" or "0", 64) .. "  " .. cmd[#cmd] }
			end,
		}
	elseif cmd[2] == "--version" then
		return {
			wait = function()
				return { code = 0, stdout = vim.json.encode({ version = version, bridge_protocol = 1 }) }
			end,
		}
	end
	return system(cmd, opts, callback)
end
config.executable = false
local installed = assert(install.install())
assert(read(installed) == binary)
assert(vim.uv.fs_stat(installed).mode % 512 == 493)
mismatch = true
local failed, checksum_err = install.install()
assert(not failed and checksum_err:find("checksum", 1, true))
assert(read(installed) == binary, "failed installation replaced the existing executable")
storage.read, vim.system, vim.fn.stdpath = read, system, stdpath
vim.fn.delete(root, "rf")
print("Task executable resolution tests passed.")
vim.cmd("qa!")
