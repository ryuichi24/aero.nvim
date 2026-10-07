-- Install the exact companion release without modifying the plugin checkout.
local M = {}
local uv = vim.uv
local plugin_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, "S").source:sub(2))))

local function manifest()
	local text, err = require("aero.tasks.storage").read(plugin_root .. "/release.json")
	local ok, release = pcall(vim.json.decode, text or "")
	if not ok or type(release) ~= "table" or type(release.version) ~= "string" then
		return nil, err or "invalid Aero release manifest"
	end
	if release.platforms ~= nil and type(release.platforms) ~= "table" then
		return nil, "invalid Aero release platforms"
	end
	local suffix = release.version:match("^%d+%.%d+%.%d+(.*)$")
	if not suffix or suffix ~= "" and not suffix:match("^%-[%w%.%-]+$") then
		return nil, "invalid Aero release version"
	end
	if release.published ~= true then
		return nil, "this development revision requires a local companion build; run make build-companion"
	end
	return release
end

function M.platform()
	local system = uv.os_uname()
	local os = ({ Darwin = "darwin", Linux = "linux" })[system.sysname]
	local arch = ({ arm64 = "arm64", aarch64 = "arm64", x86_64 = "amd64", amd64 = "amd64" })[system.machine]
	if not os or not arch then
		return nil, "unsupported companion platform; release binaries require macOS/Linux ARM64 or AMD64"
	end
	return os .. "-" .. arch
end

local function target()
	local release, err = manifest()
	if not release then
		return nil, err
	end
	local platform
	platform, err = M.platform()
	if not platform then
		return nil, err
	end
	if release.platforms and not vim.tbl_contains(release.platforms, platform) then
		return nil, "no companion release binary for " .. platform
	end
	local name = "aero-companion-" .. release.version .. "-" .. platform
	return {
		version = release.version,
		name = name,
		path = vim.fs.joinpath(vim.fn.stdpath("data"), "Aero", "bin", release.version, name),
		base = "https://github.com/ryuichi24/aero.nvim/releases/download/v" .. release.version .. "/",
	}
end

local function version_matches(path, version)
	local result = vim.system({ path, "--version" }, { text = true }):wait(5000)
	if result.code ~= 0 or vim.trim(result.stdout or "") ~= "aero-companion " .. version then
		return nil, "companion executable version mismatch (requires " .. version .. ")"
	end
	return true
end

function M.resolve()
	local release, err = target()
	if not release then
		return nil, err
	end
	if vim.fn.executable(release.path) ~= 1 then
		return nil, "Companion executable not installed. Run :Aero companion install"
	end
	local ok
	ok, err = version_matches(release.path, release.version)
	return ok and release.path or nil, err
end

local function download(url, path)
	local result = vim.system({
		"curl", "--fail", "--location", "--silent", "--show-error",
		"--proto", "=https", "--proto-redir", "=https", "--max-time", "120",
		"--output", path, url,
	}, { text = true }):wait(125000)
	if result.code ~= 0 then
		return nil, "companion release download failed: " .. vim.trim(result.stderr or "")
	end
	return true
end

function M.install()
	local release, err = target()
	local function fail(message)
		vim.notify("Aero: " .. tostring(message), vim.log.levels.ERROR)
		return nil, message
	end
	if not release then
		return fail(err)
	end
	if vim.fn.executable("curl") ~= 1 then
		return fail("companion installation requires curl")
	end
	local hasher = vim.fn.executable("sha256sum") == 1 and "sha256sum"
		or vim.fn.executable("shasum") == 1 and "shasum"
	if not hasher then
		return fail("companion installation requires sha256sum or shasum")
	end
	local temp = release.path .. "." .. tostring(uv.hrtime()) .. ".download"
	local checksums = temp .. ".checksums"
	vim.notify("Aero: downloading companion v" .. release.version)
	local progress = require("aero.exports_progress").start(release.name, {
		title = " Companion installation ",
		stage = "Downloading release checksums",
		redraw = true,
	})
	local ok, installed, install_err = pcall(function()
		vim.fn.mkdir(vim.fs.dirname(release.path), "p")
		local success, reason = download(release.base .. "SHA256SUMS", checksums)
		if not success then
			return nil, reason
		end
		local sums = require("aero.tasks.storage").read(checksums) or ""
		local expected
		for line in sums:gmatch("[^\r\n]+") do
			local hash, name = line:match("^(%x+)%s+%*?(.+)$")
			if name == release.name then
				if expected or #hash ~= 64 then
					return nil, "invalid companion release checksum entry"
				end
				expected = hash:lower()
			end
		end
		if not expected then
			return nil, "companion binary missing from release SHA256SUMS: " .. release.name
		end
		progress.update("Downloading companion binary")
		success, reason = download(release.base .. release.name, temp)
		if not success then
			return nil, reason
		end
		progress.update("Verifying SHA-256 checksum")
		local cmd = hasher == "sha256sum" and { hasher, temp } or { hasher, "-a", "256", temp }
		local result = vim.system(cmd, { text = true }):wait(10000)
		local actual = (result.stdout or ""):match("^(%x+)")
		if result.code ~= 0 or not actual or actual:lower() ~= expected then
			return nil, "companion executable checksum verification failed"
		end
		success, reason = uv.fs_chmod(temp, 493)
		if success then
			progress.update("Checking companion version")
			success, reason = version_matches(temp, release.version)
		end
		if success then
			progress.update("Installing companion")
			success, reason = uv.fs_rename(temp, release.path)
		end
		return success and release.path or nil, reason
	end)
	progress.close()
	uv.fs_unlink(temp)
	uv.fs_unlink(checksums)
	if not ok or not installed then
		return fail(ok and install_err or installed)
	end
	vim.notify("Aero: companion installed at " .. installed .. "; run :Aero companion start")
	return installed
end

return M
