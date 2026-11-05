vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
require("aero.config").setup({ companion = { auto_start = false }, browser = { cmd = { "fixture-browser" } } })
local reader = require("aero.reader")
reader.setup()
vim.t.aero_worktree = vim.fn.getcwd()
local source = api.nvim_get_current_buf()
reader.attach(api.nvim_get_current_win())
local installed, compatible, launched = false, false, nil
local tty, client_tty, client_code = "ttys999\n", "", 0
local local_ui, tmux_queries = true, 0
vim.env.TMUX_PANE = "%42"
local executable = vim.fn.executable
vim.fn.executable = function(name)
	if name == "tmux" then
		return 1
	end

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
				return { code = 0, stdout = tty }
			end

			if command[1] == "tmux" then
				assert(vim.deep_equal(command, { "tmux", "display-message", "-p", "-t", "%42", "#{client_tty}" }))

				tmux_queries = tmux_queries + 1
				return { code = client_code, stdout = client_tty }
			end

			return { code = 0, stdout = vim.json.encode({ capabilities = compatible and { "embedding" } or {} }) }
		end,
	}
end
api.nvim_list_uis = function()
	return { { width = 80, height = 24, stdin_tty = local_ui, stdout_tty = local_ui } }
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
tty = "??      \n"
vim.fn.maparg("R", "n", false, true).callback()
text = table.concat(api.nvim_buf_get_lines(setup_buf, 0, -1, false), "\n")

assert(not launched)
assert(text:find("Could not resolve a terminal device", 1, true))
assert(text:find("TMUX_PANE", 1, true))
assert(not text:find("Install terminal-browser", 1, true))
assert(not text:find("Copy install command", 1, true))

client_tty, client_code = "/dev/ttys123\n", 1
vim.fn.maparg("R", "n", false, true).callback()

assert(not launched)

client_code, local_ui = 0, false
local queries_before = tmux_queries
vim.fn.maparg("R", "n", false, true).callback()

assert(not launched)
assert(tmux_queries == queries_before)

local_ui = true
-- Even when ps resolves the pane, graphics must bypass tmux's parser.
tty = "ttys999\n"
vim.fn.maparg("R", "n", false, true).callback()

assert(launched)
assert(launched.env.PIXEL_TTY == "/dev/ttys123")
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

local frame_failure = require("aero.browser.setup").show(nil, "frame-failure-fixture", {
	code = "browser_frame_failed",
	message = "Browser frame delivery failed.",
	details = "Invalid browser frame dimensions: -1 x 10",
})
local frame_text = table.concat(api.nvim_buf_get_lines(frame_failure, 0, -1, false), "\n")

assert(frame_text:find("-1 x 10", 1, true))
assert(not frame_text:find("Install terminal-browser", 1, true))
assert(not frame_text:find("Copy install command", 1, true))

print("browser setup: missing dependency, incompatible build, retry, startup diagnostics, and health passed")
vim.cmd("qa!")
