-- Agent-reported prompt usage and cumulative fees; context snapshots are not token totals.
local config = require("aero.config")
local M = {}
local fields = { "inputTokens", "outputTokens", "totalTokens", "thoughtTokens", "cachedReadTokens", "cachedWriteTokens" }

local function amount(value)
	return type(value) == "number" and value == value and value >= 0 and value < math.huge and value or nil
end

local function count(value)
	value = amount(value)
	return value and value == math.floor(value) and value or nil
end

local function cost(value)
	if type(value) ~= "table" or not amount(value.amount) or type(value.currency) ~= "string" then
		return nil
	end
	local currency = value.currency:upper()
	if not currency:match("^[A-Z][A-Z][A-Z]$") then
		return nil
	end
	return { amount = value.amount, currency = currency }
end

local function state(chat)
	chat.usage = chat.usage or {}
	return chat.usage
end

function M.restore(chat, saved)
	if type(saved) ~= "table" then
		return
	end
	local restored = {}
	if type(saved.tokens) == "table" then
		local tokens = { responses = count(saved.tokens.responses) or 0 }
		for _, field in ipairs(fields) do tokens[field] = count(saved.tokens[field]) end
		if tokens.responses > 0 then restored.tokens = tokens end
	end
	if type(saved.context) == "table" then
		local used, size = count(saved.context.used), count(saved.context.size)
		if used and size then restored.context = { used = used, size = size } end
	end
	restored.cost = cost(saved.cost)
	if next(restored) then chat.usage = restored end
end

--- usage_update.used/size and cost are snapshots; repeated updates must never be added.
function M.update(chat, update)
	local used, size = count(update.used), count(update.size)
	local fee = cost(update.cost)
	if not (used and size) and not fee then return end
	local data = state(chat)
	if used and size then data.context = { used = used, size = size } end
	if fee then data.cost = fee end
end

--- PromptResponse.usage contains per-response consumption (as provided by OpenCode).
function M.response(chat, response, turn)
	local usage = type(response) == "table" and response.usage
	if type(usage) ~= "table" then return end
	chat.usage_seen = chat.usage_seen or {}
	if chat.usage_seen[turn] then return end
	local reported = {}
	for _, field in ipairs(fields) do reported[field] = count(usage[field]) end
	if not next(reported) then return end
	if not reported.totalTokens and reported.inputTokens and reported.outputTokens then
		reported.totalTokens = reported.inputTokens + reported.outputTokens
	end
	chat.usage_seen[turn] = true
	local data = state(chat)
	data.tokens = data.tokens or { responses = 0 }
	data.tokens.responses = data.tokens.responses + 1
	for field, value in pairs(reported) do
		data.tokens[field] = (data.tokens[field] or 0) + value
	end
end

local function number(value)
	if value == nil then return "not reported" end
	return (tostring(math.floor(value)):reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", ""))
end

local function fee(value)
	if not value then return "not reported" end
	local text
	if value.amount > 0 and value.amount < 0.000001 then
		text = ("%.8g"):format(value.amount)
	else
		text = ("%.6f"):format(value.amount):gsub("0+$", ""):gsub("%.$", ".00")
	end
	return value.currency .. " " .. text
end

local function compact(value)
	if value >= 1000000 then return ("%.1fm"):format(value / 1000000) end
	if value >= 1000 then return ("%.1fk"):format(value / 1000) end
	return tostring(value)
end

local function percentage(context)
	return context.size > 0 and (" (%.1f%%)"):format(context.used * 100 / context.size) or ""
end

function M.summary(chat)
	if config.options.acp.show_usage == false or not chat or not chat.usage then return end
	local data, parts = chat.usage, {}
	if data.tokens and data.tokens.totalTokens ~= nil then
		table.insert(parts, compact(data.tokens.totalTokens) .. " tracked tok")
	end
	if data.context then
		table.insert(parts, compact(data.context.used) .. "/" .. compact(data.context.size) .. " ctx" .. percentage(data.context))
	end
	if data.cost then table.insert(parts, fee(data.cost)) end
	return #parts > 0 and table.concat(parts, " · ") or nil
end

function M.lines(chat)
	local data = chat and chat.usage or {}
	local tokens = data.tokens or {}
	local lines = { "Tokens (reported turns): " .. number(tokens.totalTokens) }
	if tokens.responses then
		table.insert(lines, ("Reported turns: %d · Input: %s · Output: %s"):format(tokens.responses, number(tokens.inputTokens), number(tokens.outputTokens)))
	end
	local extras = {}
	for _, item in ipairs({ { "thoughtTokens", "Thinking" }, { "cachedReadTokens", "Cache read" }, { "cachedWriteTokens", "Cache write" } }) do
		if tokens[item[1]] ~= nil then table.insert(extras, item[2] .. ": " .. number(tokens[item[1]])) end
	end
	if #extras > 0 then table.insert(lines, table.concat(extras, " · ")) end
	if data.context then
		local context = data.context
		table.insert(lines, "Context: " .. number(context.used) .. " / " .. number(context.size) .. " tokens" .. percentage(context))
	end
	table.insert(lines, "Total fee (last reported): " .. fee(data.cost))
	return lines
end

return M
