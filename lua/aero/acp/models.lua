-- Model controls are local commands, backed by ACP configuration (or legacy model APIs).
local events = require("aero.events")
local M = {}

local function model_option(chat)
	local fallback
	for _, option in ipairs(chat.config_options or {}) do
		if option.type == "select" and type(option.id) == "string" then
			if option.category == "model" then
				return option
			end
			if option.id == "model" or option.name == "Model" then
				fallback = fallback or option
			end
		end
	end
	return fallback
end

function M.options(chat)
	local out = { choices = {} }
	if not chat then
		return out
	end
	local option = model_option(chat)
	if option then
		out.config_id, out.current = option.id, option.currentValue
		local function collect(options, group)
			for _, item in ipairs(options or {}) do
				if type(item.options) == "table" then
					collect(item.options, item.name or item.group)
				elseif type(item.value) == "string" then
					table.insert(out.choices, {
						id = item.value,
						name = item.name or item.value,
						description = item.description,
						group = group,
					})
				end
			end
		end
		collect(option.options)
	elseif chat.models then
		out.current = chat.models.currentModelId
		for _, item in ipairs(chat.models.availableModels or {}) do
			if type(item.modelId) == "string" then
				table.insert(
					out.choices,
					{ id = item.modelId, name = item.name or item.modelId, description = item.description }
				)
			end
		end
	end
	return out
end

function M.current(chat)
	local options = M.options(chat)
	for _, choice in ipairs(options.choices) do
		if choice.id == options.current then
			return choice.id, choice.name
		end
	end
	return options.current, options.current
end

function M.accept(chat, response)
	if type(response) ~= "table" then
		return
	end
	local previous = M.current(chat)
	if type(response.configOptions) == "table" then
		chat.config_options = response.configOptions
	end
	if type(response.models) == "table" then
		chat.models = response.models
	end
	if type(response.currentModelId) == "string" then
		chat.models = chat.models or {}
		chat.models.currentModelId = response.currentModelId
		local option = model_option(chat)
		if option then
			option.currentValue = response.currentModelId
		end
	end
	local current, name = M.current(chat)
	if previous and current and previous ~= current and chat.s.chat == chat and chat.state ~= "exited" then
		events.emit(
			"session_model_changed",
			events.session(chat.s, {
				session_id = chat.session_id,
				model_id = current,
				model_name = name,
				previous_model_id = previous,
			})
		)
	end
end

local function find(options, argument)
	for _, choice in ipairs(options.choices) do
		if choice.id == argument then
			return choice
		end
	end
	local match
	for _, choice in ipairs(options.choices) do
		if choice.name:lower() == argument:lower() then
			if match then
				return nil
			end -- Ambiguous display names require the exact ID.
			match = choice
		end
	end
	return match
end

function M.handle(chat, text)
	text = vim.trim(text)
	if text:find("[\r\n]") then
		return false
	end
	local command, argument = text:match("^/(%S+)%s*(.*)$")
	if command ~= "model" then
		return false
	end
	argument = vim.trim(argument)
	local options = M.options(chat)
	if #options.choices == 0 then
		chat:info("This agent does not expose model selection over ACP.")
		chat:changed()
		chat:flush_queue()
		return true
	end

	local function active()
		return chat.s.chat == chat and chat.state == "ready" and not chat.client.closed
	end
	local function finish()
		chat.model_pending = nil
		if active() then
			chat:changed()
			chat:flush_queue()
		end
	end
	local function select_model(value)
		if not active() then
			chat.model_pending = nil
			return
		end
		local latest = M.options(chat)
		local choice = find(latest, value)
		if not choice then
			chat:info("Unknown or ambiguous model: " .. value .. ". Use /model to select an available model.")
			return finish()
		end
		if choice.id == latest.current then
			chat:info("Current model: " .. choice.name .. " (" .. choice.id .. ")")
			return finish()
		end
		chat.model_pending = "switching model"
		chat:changed()
		require("aero.spinner").ensure()
		local method, params = "session/set_model", { sessionId = chat.session_id, modelId = choice.id }
		if latest.config_id then
			method = "session/set_config_option"
			params = { sessionId = chat.session_id, configId = latest.config_id, value = choice.id }
		end
		local previous = M.current(chat)
		chat.client:request(method, params, function(err, response)
			if not active() then
				chat.model_pending = nil
				return
			end
			if err then
				chat:fail("model change", err)
			else
				M.accept(chat, response)
				-- Legacy setters return an empty response. Do not overwrite a newer agent update.
				if not (response and (response.configOptions or response.models)) and M.current(chat) == previous then
					M.accept(chat, { currentModelId = choice.id })
				end
				local id, name = M.current(chat)
				chat:info("Model: " .. (name or choice.name) .. " (" .. (id or choice.id) .. ")")
			end
			finish()
		end)
	end

	if argument ~= "" then
		select_model(argument)
	else
		local _, current = M.current(chat)
		chat.model_pending = "choosing a model"
		chat:changed()
		vim.ui.select(options.choices, {
			prompt = "Model (current: " .. (current or "unknown") .. ")",
			format_item = function(choice)
				local group = choice.group and choice.group .. " / " or ""
				return group
					.. choice.name
					.. " ("
					.. choice.id
					.. ")"
					.. (choice.id == options.current and " [current]" or "")
			end,
		}, function(choice)
			if choice then
				select_model(choice.id)
			else
				finish()
			end
		end)
	end
	return true
end

return M
