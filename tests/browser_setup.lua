vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
require("aero.config").setup({ companion = { auto_start = false }, browser = { cmd = { "fixture-browser" } } })
local reader = require("aero.reader")
reader.setup()
vim.t.aero_worktree = vim.fn.getcwd()
local source = api.nvim_get_current_buf()
reader.attach(api.nvim_get_current_win())
local installed, compatible, launched = false, false, nil
local executable = vim.fn.executable
vim.fn.executable = function(name)
	return name == "fixture-browser" and (installed and 1 or 0) or executable(name)
end
local exepath = vim.fn.exepath
vim.fn.exepath = function(name)
	return name == "fixture-browser" and "/fixture/terminal-browser" or exepath(name)
end
vim.system = function(command)
	return {
		wait = function()
			if command[1] == "ps" then
				return { code = 0, stdout = "ttys999\n" }
			end

			return { code = 0, stdout = vim.json.encode({ capabilities = compatible and { "embedding" } or {} }) }
		end,
	}
end
api.nvim_list_uis = function()
	return { { width = 80, height = 24 } }
end
vim.fn.jobstart = function(_, options)
	launched = options
	return 123
end
vim.fn.jobstop = function()
	return 1
end
local copied, opened
vim.fn.setreg = function(_, value)
	copied = value
end
vim.ui.open = function(url)
	opened = url
end
vim.notify = function() end

reader.select("browser")
local setup_buf = api.nvim_get_current_buf()
local text = table.concat(api.nvim_buf_get_lines(setup_buf, 0, -1, false), "\n")

assert(vim.bo[setup_buf].filetype == "aero-browser-setup")
assert(text:find("Browser setup required", 1, true))
assert(text:find("Neovim's PATH", 1, true))
assert(text:find("terminal-browser setup", 1, true))
assert(not vim.bo[setup_buf].modifiable)
assert(not launched)

vim.fn.maparg("Y", "n", false, true).callback()
vim.fn.maparg("O", "n", false, true).callback()

assert(copied:find("install", 1, true))
assert(opened == require("aero.browser.setup").installation_url)

installed = true
vim.fn.maparg("R", "n", false, true).callback()

assert(api.nvim_get_current_buf() == setup_buf)
assert(not launched)
assert(table.concat(api.nvim_buf_get_lines(setup_buf, 0, -1, false)):find("embedding support", 1, true))

compatible = true
vim.fn.maparg("R", "n", false, true).callback()

assert(launched)
assert(vim.bo[api.nvim_get_current_buf()].filetype == "aero-browser")
assert(api.nvim_buf_is_valid(source))

launched.on_stderr(123, { "Fixture Chromium startup failed" })
launched.on_exit(123, 1)

assert(api.nvim_get_current_buf() == setup_buf)
assert(table.concat(api.nvim_buf_get_lines(setup_buf, 0, -1, false)):find("Fixture Chromium startup failed", 1, true))

local reports = {}

for _, method in ipairs({ "start", "ok", "warn", "error", "info" }) do
	vim.health[method] = function(message)
		reports[#reports + 1] = message
	end
end

require("aero.health").check()
local health = table.concat(reports, "\n")

assert(health:find("/fixture/terminal-browser", 1, true))
assert(health:find("embedding capability verified", 1, true))
assert(health:find("Fixture Chromium startup failed", 1, true))

reader.select("source")

assert(api.nvim_get_current_buf() == source)

print("browser setup: missing dependency, incompatible build, retry, startup diagnostics, and health passed")
vim.cmd("qa!")
