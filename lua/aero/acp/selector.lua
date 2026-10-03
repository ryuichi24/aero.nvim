-- Local session selectors backed by ACP configuration or legacy APIs.
local events = require("aero.events")
return function(kind, legacy_id)
	local M = {}
	local title = kind:sub(1, 1):upper() .. kind:sub(2)
	local state_key, current_key = kind .. "s", "current" .. title .. "Id"
	local pending_key = kind .. "_pending"

	local function config_option(chat)
		local fallback
		for _, option in ipairs(chat.config_options or {}) do
			if option.type == "select" and type(option.id) == "string" then
				if option.category == kind then
					return option
				end
				if option.id == kind or option.name == title or option.name == "Session " .. title then
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
		local option = config_option(chat)
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
		elseif chat[state_key] then
			out.current = chat[state_key][current_key]
			for _, item in ipairs(chat[state_key]["available" .. title .. "s"] or {}) do
				if type(item[legacy_id]) == "string" then
					table.insert(
						out.choices,
						{ id = item[legacy_id], name = item.name or item[legacy_id], description = item.description }
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

	function M.accept(chat, response, previous)
		if type(response) ~= "table" then
			return
		end
		previous = previous or M.current(chat)
		if type(response.configOptions) == "table" then
			chat.config_options = response.configOptions
		end
		if type(response[state_key]) == "table" then
			chat[state_key] = response[state_key]
		end
		if type(response[current_key]) == "string" then
			chat[state_key] = chat[state_key] or {}
			chat[state_key][current_key] = response[current_key]
			local option = config_option(chat)
			if option then
				option.currentValue = response[current_key]
			end
		end
		local current, name = M.current(chat)
		if previous and current and previous ~= current and chat.s.chat == chat and chat.state ~= "exited" then
			events.emit(
				"session_" .. kind .. "_changed",
				events.session(chat.s, {
					session_id = chat.session_id,
					[kind .. "_id"] = current,
					[kind .. "_name"] = name,
					["previous_" .. kind .. "_id"] = previous,
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
		if command ~= kind then
			return false
		end
		argument = vim.trim(argument)
		local options = M.options(chat)
		if #options.choices == 0 then
			chat:info("This agent does not expose " .. kind .. " selection over ACP.")
			chat:changed()
			chat:flush_queue()
			return true
		end

		local function active()
			return chat.s.chat == chat and chat.state == "ready" and not chat.client.closed
		end
		local function finish()
			chat[pending_key] = nil
			if active() then
				chat:changed()
				chat:flush_queue()
			end
		end
		local function select_value(value)
			if not active() then
				chat[pending_key] = nil
				return
			end
			local latest = M.options(chat)
			local choice = find(latest, value)
			if not choice then
				chat:info(
					"Unknown or ambiguous "
						.. kind
						.. ": "
						.. value
						.. ". Use /"
						.. kind
						.. " to select an available "
						.. kind
						.. "."
				)
				return finish()
			end
			if choice.id == latest.current then
				chat:info("Current " .. kind .. ": " .. choice.name .. " (" .. choice.id .. ")", kind)
				return finish()
			end
			chat[pending_key] = "switching " .. kind
			chat:changed()
			require("aero.spinner").ensure()
			local method, params = "session/set_" .. kind, { sessionId = chat.session_id, [kind .. "Id"] = choice.id }
			if latest.config_id then
				method = "session/set_config_option"
				params = { sessionId = chat.session_id, configId = latest.config_id, value = choice.id }
			end
			local previous = M.current(chat)
			chat.client:request(method, params, function(err, response)
				if not active() then
					chat[pending_key] = nil
					return
				end
				if err then
					chat:fail(kind .. " change", err)
				else
					chat:accept_settings(response)
					-- Legacy setters return an empty response. Do not overwrite a newer agent update.
					if
						not (response and (response.configOptions or response[state_key]))
						and M.current(chat) == previous
					then
						M.accept(chat, { [current_key] = choice.id })
					end
					local id, name = M.current(chat)
					chat:info(title .. ": " .. (name or choice.name) .. " (" .. (id or choice.id) .. ")", kind)
				end
				finish()
			end)
		end

		if argument ~= "" then
			select_value(argument)
		else
			local _, current = M.current(chat)
			chat[pending_key] = "choosing a " .. kind
			chat:changed()
			vim.ui.select(options.choices, {
				prompt = title .. " (current: " .. (current or "unknown") .. ")",
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
					select_value(choice.id)
				else
					finish()
				end
			end)
		end
		return true
	end

	return M
end
