-- Run from the repository root: nvim --headless -u NONE -l tests/models.lua
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local modes = { "config", "legacy", "unsupported", "config-no-category", "config-load" }
local agents = {}
for _, mode in ipairs(modes) do
	agents[mode] = { type = "acp", cmd = { "python3", "tests/fixtures/models.py", mode } }
end
require("aero").setup({
	state_file = dir .. "/state.json",
	animation = false,
	fullscreen_key = false,
	start_insert = false,
	agents = agents,
})
local sessions, store, panel = require("aero.session"), require("aero.store"), require("aero.panel")
local models = require("aero.acp.models")
local original_select = vim.ui.select
local changes = {}
require("aero").on("session_model_changed", function(event)
	table.insert(changes, event)
end)
local function wait(fn)
	assert(vim.wait(5000, fn, 10), "timed out")
end
local function text(s)
	return table.concat(api.nvim_buf_get_lines(s.buf, 0, -1, false), "\n")
end
local function idle(s)
	wait(function()
		return not s.chat.busy and not s.chat.model_pending
	end)
end
local created = {}

for _, mode in ipairs(modes) do
	local s = sessions.create(vim.fn.getcwd(), mode)
	table.insert(created, s)
	if mode == "config-load" then
		store.set_session_field(s.worktree, s.name, "acp_session_id", "models-session")
		s.fresh = false
	end
	assert(panel.show(s))
	api.nvim_set_current_win(panel.win())
	wait(function()
		return s.chat.state == "ready"
	end)
	local chat, id = s.chat, s.chat.session_id
	if mode == "unsupported" then
		vim.ui.select = function()
			error("unsupported agent opened a picker")
		end
		chat:prompt("/model")
		wait(function()
			return text(s):find("does not expose model selection", 1, true)
		end)
		assert(chat.session_id == id and not chat.model_pending)
	elseif mode == "config-load" then
		assert(chat.resumed and models.current(chat) == "provider/beta:fast")
		assert(vim.wo[panel.win()].winbar:find("Model Beta", 1, true))
	else
		local legacy = mode == "legacy"
		local alpha, beta =
			legacy and "legacy/alpha" or "provider/alpha", legacy and "legacy/beta" or "provider/beta:fast"
		assert(models.current(chat) == alpha)
		assert(vim.wo[panel.win()].winbar:find("Model Alpha", 1, true))
		local before = #changes
		vim.ui.select = function(choices, opts, callback)
			assert(opts.prompt:find("Model Alpha", 1, true))
			assert(opts.format_item(choices[1]):find("[current]", 1, true))
			assert(choices[2].id == beta)
			callback(choices[2])
		end
		chat:prompt("/model")
		chat:prompt("after-switch") -- Waits until the setter has succeeded.
		idle(s)
		wait(function()
			return text(s):find("reply using " .. beta .. ": after-switch", 1, true)
		end)
		assert(models.current(chat) == beta and chat.session_id == id)
		assert(#changes == before + 1, "notification and setter response emitted duplicate changes")
		assert(vim.wo[panel.win()].winbar:find("Model Beta", 1, true))
		assert(changes[#changes].model_id == beta and changes[#changes].previous_model_id == alpha)
		if not legacy then
			assert(chat.config_options[2].currentValue == "high")
		end

		-- The slash command and IDs complete independently of agent-supplied /model entries.
		chat:compose()
		vim.cmd.stopinsert()
		local prompt = chat.prompt_buf
		vim.wo.virtualedit = "onemore"
		api.nvim_buf_set_lines(prompt, 0, -1, false, { "/m" })
		api.nvim_win_set_cursor(0, { 1, 2 })
		local complete = require("aero.acp").omnifunc(0, "/m")
		assert(#complete == 1 and complete[1].word == "/model")
		local prefix = legacy and "legacy/" or "provider/"
		api.nvim_buf_set_lines(prompt, 0, -1, false, { "/model " .. prefix })
		api.nvim_win_set_cursor(0, { 1, #("/model " .. prefix) })
		assert(require("aero.acp").omnifunc(1, "") == 7)
		complete = require("aero.acp").omnifunc(0, prefix)
		assert(complete[2].word == beta)

		-- Sending /model through :w/C-s's handler switches without a session/prompt RPC.
		api.nvim_buf_set_lines(prompt, 0, -1, false, { "/model " .. alpha })
		chat:send_prompt_buf()
		idle(s)
		assert(models.current(chat) == alpha)
		assert(not text(s):find("## You\n\n/model", 1, true))

		vim.ui.select = function(_, _, callback)
			callback(nil)
		end
		chat:prompt("/model")
		assert(not chat.model_pending and models.current(chat) == alpha)
		chat:prompt("/model not-a-model")
		assert(models.current(chat) == alpha and not chat.model_pending)
		if not legacy then
			chat:prompt("/model provider/reject")
			idle(s)
			wait(function()
				return text(s):find("Model unavailable", 1, true)
			end)
			assert(models.current(chat) == alpha, "failed model change updated the selected model")
		end

		chat:prompt("first-turn")
		chat:prompt("/model " .. beta)
		chat:prompt("second-turn")
		idle(s)
		wait(function()
			return text(s):find("reply using " .. beta .. ": second-turn", 1, true)
		end)
		assert(models.current(chat) == beta)
		if not legacy then
			chat:prompt("agent-update")
			idle(s)
			assert(models.current(chat) == alpha, "agent configuration update was ignored")
		end
	end
	vim.ui.select = original_select
end

for _, s in ipairs(created) do
	sessions.delete(s)
end
api.nvim_create_autocmd("VimLeavePre", {
	once = true,
	callback = function()
		vim.fn.delete(dir, "rf")
	end,
})
print(
	"Model tests passed (config options, grouped choices, legacy setters, completion, queues, load/update metadata, failures)."
)
