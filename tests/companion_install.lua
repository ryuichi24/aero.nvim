vim.opt.rtp:prepend(vim.fn.getcwd())
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero").setup({ state_file = root .. "/state.json" })
vim.cmd("runtime plugin/aero.lua")
assert(vim.tbl_contains(vim.fn.getcompletion("Aero companion in", "cmdline"), "install"))

local installer = require("aero.companion_install")
local storage = require("aero.tasks.storage")
local read, system, stdpath, uname = storage.read, vim.system, vim.fn.stdpath, vim.uv.os_uname
local release = { version = "9.8.7-fixture", published = true }
local asset = "aero-companion-" .. release.version .. "-" .. assert(installer.platform())
local binary = "#!/bin/sh\nprintf '%s\\n' 'aero-companion " .. release.version .. "'\n"
local fixture = root .. "/fixture"
local function expected_hash()
	local file = assert(io.open(fixture, "wb"))
	file:write(binary)
	file:close()
	local cmd = vim.fn.executable("sha256sum") == 1 and { "sha256sum", fixture }
		or { "shasum", "-a", "256", fixture }
	local result = system(cmd, { text = true }):wait()
	assert(result.code == 0)
	return assert(result.stdout:match("^(%x+)"))
end
storage.read = function(path)
	if path:match("/release.json$") then
		return vim.json.encode(release)
	end
	return read(path)
end
vim.fn.stdpath = function(kind)
	return kind == "data" and root .. "/data" or stdpath(kind)
end
local downloads, mode = 0, "success"
local elapsed_during_download = false
local windows = #vim.api.nvim_list_wins()
vim.system = function(cmd, opts, callback)
	if cmd[1] ~= "curl" then
		return system(cmd, opts, callback)
	end
	downloads = downloads + 1
	local url, path = cmd[#cmd], cmd[#cmd - 1]
	local progress_win
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_config(win).title then
			progress_win = win
		end
	end
	assert(progress_win, "download has no visible progress window")
	local lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(progress_win), 0, -1, false)
	local stage = url:match("SHA256SUMS$") and "Downloading release checksums" or "Downloading companion binary"
	assert(lines[1]:find(stage, 1, true), "incorrect download progress stage")
	assert(lines[2] == asset, "progress should identify the release asset")
	local base = "https://github.com/ryuichi24/aero.nvim/releases/download/v" .. release.version .. "/"
	assert(url == base .. "SHA256SUMS" or url == base .. asset, "wrong release selected")
	assert(vim.tbl_contains(cmd, "=https"))
	if mode == "exception" then
		error("fixture download exception")
	end
	local file = assert(io.open(path, "wb"))
	if url:match("SHA256SUMS$") then
		local hash = mode == "checksum" and string.rep("0", 64) or expected_hash()
		local entry = mode == "missing" and "unrelated-binary" or asset
		file:write(hash .. "  " .. entry .. "\n")
	else
		file:write(binary)
	end
	file:close()
	local result = { code = mode == "download" and 22 or 0, stdout = "", stderr = "fixture HTTP 404" }
	if downloads == 1 then
		-- A real subprocess reproduces the event-loop behavior of a slow download.
		vim.defer_fn(function()
			local current = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(progress_win), 0, 1, false)[1]
			elapsed_during_download = current:match("· [1-9]%d*s") ~= nil
		end, 1200)
		return system({ "sh", "-c", "sleep 1.5" }, opts, function()
			callback(result)
		end)
	end
	if callback then
		vim.schedule(function()
			callback(result)
		end)
	end
	return {
		wait = function()
			return result
		end,
	}
end

local path, err = installer.resolve()
assert(not path and err:find(":Aero companion install", 1, true))
-- Exercise the actual user command; installation does not launch the bridge.
vim.cmd("Aero companion install")
assert(elapsed_during_download, "elapsed time did not refresh while the download was running")
assert(#vim.api.nvim_list_wins() == windows, "successful install left progress open")
path = assert(installer.resolve())
assert(path == vim.fs.joinpath(root, "data", "Aero", "bin", release.version, asset))
assert(read(path) == binary)
assert(vim.uv.fs_stat(path).mode % 512 == 493)
assert(not require("aero.companion").status().running)
local previous = binary
local function clean_directory()
	for name in vim.fs.dir(vim.fs.dirname(path)) do
		assert(name == asset, "installer left temporary files: " .. name)
	end
end
local function failure(kind, expected)
	mode = kind
	local result, message = installer.install()
	assert(#vim.api.nvim_list_wins() == windows, "failed install left progress open")
	assert(not result and message:find(expected, 1, true), tostring(message))
	assert(read(path) == previous, "failed install replaced existing binary")
	clean_directory()
end
failure("checksum", "checksum verification failed")
failure("missing", "missing from release SHA256SUMS")
failure("download", "download failed")
failure("exception", "fixture download exception")
binary = "#!/bin/sh\nprintf '%s\\n' 'aero-companion 0.0.0'\n"
failure("success", "version mismatch")
binary = previous

local before = downloads
release.published = false
failure("success", "development revision")
release.published = true
release.version = "../../invalid"
failure("success", "invalid Aero release version")
release.version = "9.8.7-fixture"
vim.uv.os_uname = function()
	return { sysname = "Windows_NT", machine = "AMD64" }
end
failure("success", "unsupported companion platform")
vim.uv.os_uname = uname
release.platforms = { "unsupported-target" }
failure("success", "no companion release binary")
release.platforms = nil
assert(downloads == before, "invalid target triggered network access")

local chmod = vim.uv.fs_chmod
vim.uv.fs_chmod = function()
	return nil, "fixture chmod failure"
end
failure("success", "fixture chmod failure")
vim.uv.fs_chmod = chmod
local rename = vim.uv.fs_rename
vim.uv.fs_rename = function()
	return nil, "fixture rename failure"
end
failure("success", "fixture rename failure")
vim.uv.fs_rename = rename
assert(installer.install() == path)
clean_directory()

-- Startup selects the managed binary when no local build is present.
local companion, ui = require("aero.companion"), require("aero.companion_ui")
local executable, jobstart, start, show = vim.fn.executable, vim.fn.jobstart, companion.start, ui.show
vim.fn.executable = function(name)
	if name:match("/apps/companion/aero%-companion$") then
		return 0
	end
	return executable(name)
end
local launched
vim.fn.jobstart = function(cmd)
	launched = cmd[1]
	return -1 -- Check the selected command without starting a web bridge.
end
companion.start = function()
	return nil, root .. "/settings.json"
end
ui.show = function() end
local started, start_err = pcall(companion.launch)
assert(not started and start_err:find("could not launch", 1, true))
assert(launched == path, "startup did not select the installed release")
vim.fn.executable, vim.fn.jobstart, companion.start, ui.show = executable, jobstart, start, show

storage.read, vim.system, vim.fn.stdpath = read, system, stdpath
vim.fn.delete(root, "rf")
print("Companion installation: command, release selection, checksum, version, and atomic replacement passed")
vim.cmd("qa!")
