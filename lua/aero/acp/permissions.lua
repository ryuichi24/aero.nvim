-- Permission queue and auto-yes policy. Protocol responses are explicit; editor effects are supplied by the caller.
local M = {}

local function allow_option(options)
	local allow

	for _, option in ipairs(options or {}) do
		if option.kind == "allow_once" or option.kind == "allow_always" then
			allow = allow or option

			if option.kind == "allow_once" then
				return option
			end
		end
	end

	return allow
end

--- Record a request and respond immediately when auto-yes permits it.
--- Return the block and whether it was queued for user attention.
function M.request(chat, params, respond)
	local allow = allow_option(params.options)
	local tool = params.toolCall or {}
	local known = chat.tools[tool.toolCallId]
	local block = {
		kind = "permission",
		timestamp = os.time(),
		title = tool.title or (known and known.title) or "tool call",
		options = vim.deepcopy(params.options or {}),
	}
	table.insert(chat.blocks, block)

	if chat.auto_yes and allow then
		block.answer = (allow.name or allow.optionId) .. " (auto yes)"
		respond({ outcome = { outcome = "selected", optionId = allow.optionId } })
		return block, false
	end

	if allow then
		local id = "aero:auto-yes"
		local used = {}

		for _, option in ipairs(block.options) do
			used[option.optionId] = true
		end

		while used[id] do
			id = id .. ":"
		end
		table.insert(block.options, {
			optionId = id,
			name = "Auto yes for this conversation",
			kind = "allow_once",
			auto_yes = allow.optionId,
		})
	end

	chat.permissions = chat.permissions or {}
	local request = { params = params, respond = respond, block = block }
	table.insert(chat.permissions, request)
	chat.permission = chat.permission or request
	return block, true
end

local function approve_pending(chat, effects)
	-- Responses may change the queue synchronously; walk a stable membership snapshot.
	for _, request in ipairs(vim.list_extend({}, chat.permissions or {})) do
		for index, option in ipairs(request.block.options) do
			if option.auto_yes then
				M.choose(chat, index, request.block, effects)
				break
			end
		end
	end
end

--- Effects update pending-option UI before a response and follow output after answers.
function M.choose(chat, index, block, effects)
	local pending = chat.permission

	if block then
		pending = nil

		for _, request in ipairs(chat.permissions or {}) do
			if request.block == block then
				pending = request
				break
			end
		end
	end

	local choice = pending and pending.block.options[index]

	if not choice then
		return
	end

	for position, request in ipairs(chat.permissions or {}) do
		if request == pending then
			table.remove(chat.permissions, position)
			break
		end
	end

	chat.permission = chat.permissions and chat.permissions[1]
	effects.pending(chat)
	pending.block.answer = choice.name or choice.optionId

	if choice.auto_yes then
		chat.auto_yes = true
	end

	pending.respond({ outcome = { outcome = "selected", optionId = choice.auto_yes or choice.optionId } })

	if choice.auto_yes then
		approve_pending(chat, effects)
	end

	effects.answered(chat)
end

function M.toggle_auto_yes(chat, effects)
	chat.auto_yes = not chat.auto_yes

	if chat.auto_yes then
		approve_pending(chat, effects)
	end

	return chat.auto_yes
end

--- Adapter exit drops callbacks without responding on a closed connection.
function M.clear(chat)
	chat.permissions, chat.permission = {}, nil
end

function M.cancel(chat, before_respond)
	if not chat.permission then
		return
	end

	local pending = chat.permissions or { chat.permission }
	M.clear(chat)
	before_respond(chat)

	for _, request in ipairs(pending) do
		request.block.answer = "cancelled"
		request.respond({ outcome = { outcome = "cancelled" } })
	end
end

return M
