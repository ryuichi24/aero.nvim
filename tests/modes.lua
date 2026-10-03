-- Run from the repository root: nvim --headless -u NONE -l tests/modes.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local variants =
	{ "config", "config-no-category", "config-load", "legacy", "legacy-notify", "legacy-load", "unsupported" }
local agents = {}
for _, variant in ipairs(variants) do
	agents[variant] = { type = "acp", cmd = { "python3", "tests/fixtures/modes.py", variant } }
end
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	fullscreen_key = false,
	start_insert = false,
	agents = agents,
})
local sessions, store, panel = require("aero.session"), require("aero.store"), require("aero.panel")
local modes, models = require("aero.acp.modes"), require("aero.acp.models")
local original_select = vim.ui.select
local changes, model_changes = {}, {}
require("aero").on("session_mode_changed", function(event)
	table.insert(changes, event)
end)
require("aero").on("session_model_changed", function(event)
	table.insert(model_changes, event)
end)
local function wait(fn)
	assert(vim.wait(5000, fn, 10), "timed out")
end
local function text(s)
	return table.concat(api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n")
end
local function idle(chat)
	wait(function()
		return not chat.busy and not chat.mode_pending and #chat.queue == 0
	end)
end

for _, variant in ipairs(variants) do
	local s = sessions.create(vim.fn.getcwd(), variant)
	if variant:find("load", 1, true) then
		store.set_session_field(s.worktree, s.name, "acp_session_id", "modes-session")
		s.fresh = false
	end
	assert(panel.show(s))
	api.nvim_set_current_win(panel.win())
	wait(function()
		return s.chat.state == "ready"
	end)
	local chat, id = s.chat, s.chat.session_id
	if variant == "unsupported" then
		vim.ui.select = function()
			error("unsupported agent opened picker")
		end
		chat:prompt("/mode")
		wait(function()
			return text(s):find("does not expose mode selection", 1, true)
		end)
		assert(not chat.mode_pending)
	elseif variant:find("load", 1, true) then
		assert(chat.resumed and modes.current(chat) == "plan")
		assert(vim.wo[panel.win()].winbar:find("Plan", 1, true))
	else
		assert(modes.current(chat) == "build")
		assert(vim.wo[panel.win()].winbar:find("Build", 1, true))
		local before, model_before = #changes, #model_changes
		vim.ui.select = function(choices, opts, callback)
			assert(opts.prompt:find("Build", 1, true))
			assert(opts.format_item(choices[1]):find("[current]", 1, true))
			callback(choices[2])
		end
		chat:prompt("/mode")
		chat:prompt("after-switch")
		idle(chat)
		wait(function()
			return text(s):find("reply in plan: after-switch", 1, true)
		end)
		assert(modes.current(chat) == "plan" and chat.session_id == id)
		assert(#changes == before + 1, "duplicate mode events")
		assert(changes[#changes].mode_id == "plan" and changes[#changes].previous_mode_id == "build")
		assert(vim.wo[panel.win()].winbar:find("Plan", 1, true))
		if variant:match("^config") then
			assert(models.current(chat) == "beta" and #model_changes == model_before + 1)
		end

		chat:compose()
		vim.cmd.stopinsert()
		vim.wo.virtualedit = "onemore"
		api.nvim_buf_set_lines(chat.prompt_buf, 0, -1, false, { "/mode p" })
		api.nvim_win_set_cursor(0, { 1, 7 })
		assert(require("aero.acp").omnifunc(1, "") == 6)
		local complete = require("aero.acp").omnifunc(0, "p")
		assert(#complete == 1 and complete[1].word == "plan")
		api.nvim_buf_set_lines(chat.prompt_buf, 0, -1, false, { "/mode Build" })
		chat:send_prompt_buf()
		idle(chat)
		assert(modes.current(chat) == "build")
		assert(not text(s):find("## You\n\n/mode", 1, true))

		vim.ui.select = function(_, _, callback)
			callback(nil)
		end
		chat:prompt("/mode")
		assert(not chat.mode_pending and modes.current(chat) == "build")
		chat:prompt("/mode invalid")
		assert(not chat.mode_pending and modes.current(chat) == "build")
		chat:prompt("/mode reject")
		idle(chat)
		wait(function()
			return text(s):find("Mode unavailable", 1, true)
		end)
		assert(modes.current(chat) == "build")

		chat:prompt("first-turn")
		chat:prompt("/mode plan")
		chat:prompt("second-turn")
		idle(chat)
		wait(function()
			return text(s):find("reply in plan: second-turn", 1, true)
		end)
		chat:prompt("agent-update")
		idle(chat)
		assert(modes.current(chat) == "build")
		assert(vim.wo[panel.win()].winbar:find("Build", 1, true))
	end
	vim.ui.select = original_select
	sessions.delete(s)
end
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print(
	"Mode tests passed (config/legacy, picker, completion, queues, load, updates, dependent model changes, failures)."
)
