-- Agent contract over the shared task service. Bindings are runtime-only.
local tasks = require("aero.tasks")
local storage = require("aero.tasks.storage")
local M = {}
local cache, order = {}, {}
local limit = 256

local function failure(code, message, actual)
	return nil, { code = code, message = message, actual = actual }
end

local function resolve(binding)
	if type(binding) == "table" and binding.revoked then
		return failure("NOT_FOUND", "task binding expired")
	end
	if type(binding) ~= "table" or not binding.workspace or not binding.board_id or not binding.ticket_id then
		return failure("INVALID_ARGUMENT", "invalid task binding")
	end
	local board, err = tasks.resolve_board(binding.workspace, binding.board_id)
	if not board then
		return nil, err
	end
	local ticket, state = tasks.resolve_ticket(board, binding.ticket_id)
	if not ticket then
		return nil, state
	end
	return { board = board, ticket = ticket, state = state }
end

local function dirty(path)
	return not storage.unmodified(path)
end

local function snapshot(context)
	local board, ticket = context.board, context.ticket
	local states = {}
	for _, state in ipairs(board.states) do
		table.insert(states, state.name)
	end
	return {
		board_id = board.metadata.id,
		ticket_id = ticket.metadata.id,
		board_path = board.path,
		ticket_path = ticket.path,
		metadata = vim.deepcopy(ticket.metadata),
		title = ticket.metadata.title,
		body = table.concat(vim.list_slice(ticket.lines, ticket.frontmatter.finish + 1), "\n"),
		state = context.state,
		states = states,
		committed = true,
		board_revision = tasks.revision(board.text),
		ticket_revision = tasks.revision(ticket.text),
		dirty = {
			board_projection = require("aero.tasks.view").status(board.path),
			board_source = dirty(board.path),
			ticket = dirty(ticket.path),
		},
	}
end

function M.get_ticket(binding)
	local context, err = resolve(binding)
	if not context then
		return nil, err
	end
	return snapshot(context)
end

function M.get_board(binding)
	local context, err = resolve(binding)
	if not context then
		return nil, err
	end
	local board = context.board
	local states = {}
	for _, state in ipairs(board.states) do
		local tickets = {}
		for _, item in ipairs(state.entries) do
			table.insert(
				tickets,
				{ id = item.ticket and item.ticket.metadata.id, path = item.path, error = item.error }
			)
		end
		table.insert(states, { name = state.name, tickets = tickets })
	end
	return {
		id = board.metadata.id,
		path = board.path,
		metadata = board.metadata,
		states = states,
		diagnostics = board.diagnostics,
		committed = true,
		board_revision = tasks.revision(board.text),
		dirty = snapshot(context).dirty,
	}
end

function M.list_boards(binding)
	local context, err = resolve(binding)
	if not context then
		return nil, err
	end
	local result = {}
	for _, board in ipairs(tasks.list(binding.workspace)) do
		table.insert(result, {
			id = board.metadata and board.metadata.id,
			path = board.path,
			title = board.metadata and board.metadata.title,
			valid = board.valid,
			diagnostics = board.diagnostics,
		})
	end
	return { boards = result }
end

local function mutate(binding, method, request)
	if
		type(request) ~= "table"
		or type(request.operation_id) ~= "string"
		or #request.operation_id == 0
		or #request.operation_id > 128
	then
		return failure("INVALID_ARGUMENT", "a bounded operation_id is required")
	end
	local context, err = resolve(binding)
	if not context then
		return nil, err
	end
	local key = vim.json.encode({
		binding.workspace.root,
		binding.board_id,
		binding.ticket_id,
		binding.session_key or "",
		request.operation_id,
	})
	-- Deep equality is independent of JSON object key order.
	local payload = { method = method, request = request }
	if cache[key] then
		if not vim.deep_equal(cache[key].payload, payload) then
			return failure("INVALID_ARGUMENT", "operation_id was already used with different arguments")
		end
		return unpack(vim.deepcopy(cache[key].result), 1, 2)
	end
	local placement = method == "move_ticket"
	local expected = placement and request.expected_board_revision or request.expected_ticket_revision
	if type(expected) ~= "string" then
		return failure("INVALID_ARGUMENT", "expected document revision is required")
	end
	local options = {
		guard = function(board, ticket_path, document)
			local latest, resolve_err = resolve(binding)
			if not latest then
				return nil, resolve_err
			end
			if latest.board.path ~= board.path or latest.ticket.path ~= ticket_path then
				return failure("CONFLICT", "task identity changed")
			end
			local actual = snapshot(latest)
			if
				(placement and board.text ~= latest.board.text)
				or (not placement and document.text ~= latest.ticket.text)
			then
				return failure("CONFLICT", "task changed during validation; reread before retrying", actual)
			end
			if
				expected ~= (placement and actual.board_revision or actual.ticket_revision)
				or (request.expected_state ~= nil and request.expected_state ~= actual.state)
			then
				return failure("CONFLICT", "committed task changed; reread before retrying", actual)
			end
			if
				placement
				and (
					actual.dirty.board_projection.dirty
					or actual.dirty.board_projection.missing_column
					or actual.dirty.board_source
				)
			then
				return failure("UNSAVED_BOARD", "save or discard the board draft before moving this ticket")
			end
			if actual.dirty.ticket then
				return failure("UNSAVED_DOCUMENT", "save or discard the ticket draft before updating it")
			end
			return true
		end,
	}
	local ok
	if placement then
		if type(request.target_state) ~= "string" then
			return failure("INVALID_ARGUMENT", "target_state is required")
		end
		if
			not vim.iter(context.board.states):any(function(state)
				return state.name == request.target_state
			end)
		then
			return failure("INVALID_ARGUMENT", "unknown target state")
		end
		if
			request.position ~= nil
			and (type(request.position) ~= "number" or request.position % 1 ~= 0 or request.position < 1)
		then
			return failure("INVALID_ARGUMENT", "position must be a positive integer")
		end
		if request.position then
			for _, state in ipairs(context.board.states) do
				if state.name == request.target_state then
					local maximum = #state.entries + (state.name == context.state and 0 or 1)
					if request.position > maximum then
						return failure("INVALID_ARGUMENT", "position exceeds the target state's ticket count")
					end
				end
			end
		end
		ok, err = tasks.move_ticket(
			binding.workspace,
			context.board.path,
			context.ticket.path,
			request.target_state,
			request.position,
			options
		)
	elseif method == "update_ticket_body" then
		ok, err = tasks.update_body(binding.workspace, context.board.path, context.ticket.path, request.body, options)
	else
		local allowed = { priority = true, tags = true, assignees = true, due_date = true, estimate = true }
		if type(request.changes) ~= "table" then
			return failure("INVALID_ARGUMENT", "changes must be an object")
		end
		for field in pairs(request.changes) do
			if not allowed[field] then
				return failure("INVALID_ARGUMENT", "unsupported metadata field: " .. tostring(field))
			end
		end
		local validation = require("aero.tasks.frontmatter").validate(
			vim.tbl_extend("force", context.ticket.metadata, request.changes),
			"ticket"
		)
		if #validation > 0 then
			return failure("INVALID_ARGUMENT", table.concat(validation, "; "))
		end
		ok, err =
			tasks.update_metadata(binding.workspace, context.board.path, context.ticket.path, request.changes, options)
	end
	local result
	if ok then
		result, err = M.get_ticket(binding)
		if result then
			vim.schedule(function()
				vim.api.nvim_exec_autocmds("User", {
					pattern = "AeroTaskChanged",
					data = {
						workspace = binding.workspace,
						board_id = binding.board_id,
						ticket_id = binding.ticket_id,
						board_path = context.board.path,
						ticket_path = context.ticket.path,
						board_revision = result.board_revision,
						ticket_revision = result.ticket_revision,
					},
				})
			end)
		end
	elseif type(err) ~= "table" then
		local actual = M.get_ticket(binding)
		local code = "IO_ERROR"
		if tostring(err):find("lock is held", 1, true) then
			code = "LOCK_HELD"
		elseif actual then
			if placement and (actual.dirty.board_projection.dirty or actual.dirty.board_source) then
				code = "UNSAVED_BOARD"
			elseif actual.dirty.ticket then
				code = "UNSAVED_DOCUMENT"
			elseif expected ~= (placement and actual.board_revision or actual.ticket_revision) then
				code = "CONFLICT"
			end
		end
		err = { code = code, message = tostring(err), actual = code == "CONFLICT" and actual or nil }
	end
	cache[key] = { payload = vim.deepcopy(payload), result = { result, err } }
	table.insert(order, key)
	if #order > limit then
		cache[table.remove(order, 1)] = nil
	end
	return result, err
end

for _, method in ipairs({ "move_ticket", "update_ticket_body", "update_ticket_metadata" }) do
	M[method] = function(binding, request)
		return mutate(binding, method, request)
	end
end

return M
