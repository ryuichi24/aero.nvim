local M = {}
local installer = require("aero.install_progress")
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2)))))
local function manifest()
	local text, err = require("aero.tasks.storage").read(plugin_root .. "/release.json")
	local ok, data = pcall(vim.json.decode, text or "")
	if not ok or type(data) ~= "table" then
		return nil, err or "invalid Aero release manifest"
	end
	return data
end

function M.platform()
	local system = vim.uv.os_uname()
	local os = ({ Darwin = "darwin", Linux = "linux" })[system.sysname]
	local arch = ({ arm64 = "arm64", aarch64 = "arm64", x86_64 = "amd64", amd64 = "amd64" })[system.machine]
	if not os or not arch then
		return nil, "unsupported task transport/platform; use a native custom build on macOS/Linux"
	end
	return os .. "-" .. arch
end

local function installed_path(release)
	local platform, err = M.platform()
	if not platform then
		return nil, err
	end
	return vim.fs.joinpath(
		vim.fn.stdpath("data"),
		"Aero",
		"bin",
		release.version,
		"aero-mcp-" .. release.version .. "-" .. platform
	)
end

local function version_matches(path, release, configured)
	local result = installer.wait({ path, "--version" }, 5000)
	local ok, version = pcall(vim.json.decode, result.stdout or "")
	if
		result.code ~= 0
		or not ok
		or type(version) ~= "table"
		or version.bridge_protocol ~= release.bridge_protocol
		or version.version ~= release.version
	then
		local detected = ok
				and type(version) == "table"
				and (tostring(version.version) .. ", bridge protocol " .. tostring(version.bridge_protocol))
			or "invalid --version response"
		return nil,
			"task executable version mismatch at "
				.. path
				.. " (requires "
				.. release.version
				.. ", bridge protocol "
				.. release.bridge_protocol
				.. "; got "
				.. detected
				.. "). "
				.. (
					configured
						and "Rebuild tasks.agent.executable with make build-mcp, or set it to false and run :Aero tasks install."
					or "Run :Aero tasks install to reinstall the matching release."
				)
	end
	return true
end

function M.resolve(executable)
	local release, release_err = manifest()
	if not release then
		return nil, release_err
	end
	local path = executable or require("aero.config").options.tasks.agent.executable
	local configured = type(path) == "string" and path ~= ""
	if type(path) ~= "string" or path == "" then
		if not release.published then
			return nil, "this development revision requires tasks.agent.executable; build apps/mcp/cmd/aero-mcp locally"
		end
		local err
		path, err = installed_path(release)
		if not path then
			return nil, err
		end
	end
	path = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
	if vim.fn.executable(path) ~= 1 then
		return nil, "task executable is not executable: " .. path
	end
	local ok, err = version_matches(path, release, configured)
	if not ok then
		return nil, err
	end
	return path
end
function M.install()
	local release, err = manifest()
	if not release then
		vim.notify(err, vim.log.levels.ERROR)
		return nil, err
	end
	local configured = require("aero.config").options.tasks.agent.executable
	if release.published and (type(configured) ~= "string" or configured == "") then
		local path, path_err = installed_path(release)
		if not path then
			vim.notify(path_err, vim.log.levels.WARN)
			return nil, path_err
		end
		local parent = vim.fs.dirname(path)
		vim.fn.mkdir(parent, "p")
		local temp = path .. "." .. require("aero.tasks.storage").id("download")
		local checksum_file = temp .. ".checksums"
		local base = "https://github.com/ryuichi24/aero.nvim/releases/download/v" .. release.version .. "/"
		local progress = require("aero.exports_progress").start(vim.fs.basename(path), {
			title = " Tasks installation ",
			stage = "Downloading release checksums",
			redraw = true,
		})
		local protected, ok, download_err = pcall(function()
			local ok, download_err =
				installer.download(base .. "SHA256SUMS", checksum_file, progress, "Downloading release checksums")
			if ok then
				ok, download_err =
					installer.download(base .. vim.fs.basename(path), temp, progress, "Downloading tasks binary")
			end
			if ok then
				progress.update("Verifying SHA-256 checksum")
				local sums = require("aero.tasks.storage").read(checksum_file) or ""
				local expected
				for line in sums:gmatch("[^\r\n]+") do
					local hash, name = line:match("^(%x+)%s+%*?(.+)$")
					if name == vim.fs.basename(path) then
						expected = hash
					end
				end
				local hash_cmd = vim.fn.executable("sha256sum") == 1 and { "sha256sum", temp }
					or { "shasum", "-a", "256", temp }
				local hash_result = installer.wait(hash_cmd, 10000)
				local actual = (hash_result.stdout or ""):match("^(%x+)")
				if not expected or #expected ~= 64 or hash_result.code ~= 0 or actual ~= expected then
					ok, download_err = false, "task executable checksum verification failed"
				end
			end
			if ok then
				ok, download_err = vim.uv.fs_chmod(temp, 493)
			end
			if ok then
				progress.update("Checking tasks version")
				ok, download_err = version_matches(temp, release, false)
			end
			if ok then
				progress.update("Installing tasks binary")
				ok, download_err = vim.uv.fs_rename(temp, path)
			end
			return ok, download_err
		end)
		progress.close()
		if not protected then
			download_err, ok = ok, false
		end
		vim.uv.fs_unlink(temp)
		vim.uv.fs_unlink(checksum_file)
		if not ok then
			vim.notify(download_err, vim.log.levels.ERROR)
			return nil, download_err
		end
	end
	local path
	path, err = M.resolve()
	vim.notify(path or err, path and vim.log.levels.INFO or vim.log.levels.WARN)
	return path, err
end
return M
