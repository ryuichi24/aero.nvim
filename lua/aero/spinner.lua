-- A shared animation clock for busy sessions: one timer that ticks while anything is animating,
-- so the transcript footer, the panel winbar and the dashboard spin in step.
local config = require("aero.config")

local M = {}

local frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local interval = 80

---@type (fun(): boolean)[] each redraws its part and returns whether it still wants frames
local listeners = {}
local timer

--- The current spinner frame (the static busy icon when animation is off).
function M.frame()
	if config.options.animation == false then
		return config.options.icons.busy
	end
	return frames[math.floor(vim.uv.now() / interval) % #frames + 1]
end

--- Register a redraw callback run on every frame; it returns true while it has something to animate.
function M.on_frame(fn)
	table.insert(listeners, fn)
end

local function stop()
	if timer then
		timer:stop()
		timer:close()
		timer = nil
	end
end

local function tick()
	local any = false
	for _, fn in ipairs(listeners) do
		local ok, more = pcall(fn)
		any = any or (ok and more)
	end
	if not any then
		stop()
	end
end

--- Start the clock if it isn't running. Call when something becomes busy.
function M.ensure()
	if timer or config.options.animation == false then
		return
	end
	timer = vim.uv.new_timer()
	timer:start(interval, interval, vim.schedule_wrap(tick))
end

--- "12s", "3m 05s"
function M.elapsed(since)
	local s = math.floor((vim.uv.now() - since) / 1000)
	if s < 60 then
		return s .. "s"
	end
	return ("%dm %02ds"):format(math.floor(s / 60), s % 60)
end

return M
