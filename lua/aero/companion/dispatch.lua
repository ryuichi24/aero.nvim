-- Private scoped companion protocol: no eval, editor commands, or Neovim RPC.
local M = {}
local uv = vim.uv
local identities = setmetatable({}, { __mode = "k" })
local permissions = setmetatable({}, { __mode = "k" })
local conversation_ids = setmetatable({}, { __mode = "k" })
local receipts = require("aero.companion.receipts").new()
local worktree_cache, worktree_cache_at, worktree_roots = {}, -5000, ""
local worktree_pending = {}
local epoch = (assert(uv.random(24)):gsub(".", function(c)
	return ("%02x"):format(c:byte())
end))
local lifecycle = {
	session_create = true,
	session_update = true,
	session_resume = true,
	session_rename = true,
	session_delete = true,
	worktree_create = true,
	worktree_rename = true,
	worktree_delete = true,
}

local function worktrees()
	local workspaces = require("aero.scenes").workspaces(true)
	local roots = vim.json.encode(workspaces)

	if roots ~= worktree_roots or uv.now() - worktree_cache_at >= 5000 then
		worktree_cache_at, worktree_roots = uv.now(), roots

		for _, workspace in ipairs(workspaces) do
			local root = workspace.root

			if not worktree_pending[root] then
				worktree_pending[root] = true
				require("aero.git").list_async(root, function(list)
					worktree_pending[root] = nil
					worktree_cache[root] = list or worktree_cache[root] or {}
				end)
			end
		end
	end

	local list = {}

	for _, repository in
		ipairs(require("aero.repositories").list(function(ws)
			return worktree_cache[ws.root] or { { path = ws.root } }
		end, true))
	do
		for _, tree in ipairs(repository.list) do
			local wt = vim.deepcopy(tree)
			wt.workspace = repository.ws.root
			list[wt.path] = wt
		end
	end

	for _, path in ipairs(require("aero.store").session_worktrees()) do
		if path ~= require("aero.general").directory() then
			list[path] = list[path] or { path = path }
		end
	end

	local result = vim.tbl_values(list)
	table.sort(result, function(a, b)
		return a.path < b.path
	end)
	return result
end

local function identity(object, registry)
	if not registry[object] then
		registry[object] = (assert(uv.random(24)):gsub(".", function(c)
			return ("%02x"):format(c:byte())
		end))
	end

	return registry[object]
end

local function describe(s, boards, summary)
	return require("aero.companion.snapshot").describe(
		s,
		boards,
		identity,
		identities,
		permissions,
		conversation_ids,
		summary
	)
end

function M.dispatch(method, params)
	params = params or {}
	local sessions = require("aero.session").all()

	if method == "snapshot" then
		return require("aero.companion.snapshot").build(epoch, worktrees(), sessions, function(s, boards)
			return describe(s, boards, params.summary == true)
		end, function(chat)
			return identity(chat, identities)
		end)
	end

	if method == "session_snapshot" then
		if params.epoch ~= epoch then
			return nil, "stale host epoch"
		end

		for _, session in ipairs(sessions) do
			if session.key == params.session then
				local summary = describe(session, nil, true)

				if summary.target ~= params.target or (summary.conversation or "") ~= (params.conversation or "") then
					return nil, "stale session or conversation"
				end

				local detail = describe(session)
				local activity = detail.activity
				detail.activity = nil
				local cursor = vim.fn.sha256(vim.json.encode(detail))
				detail.activity = activity

				if params.cursor == cursor then
					return { cursor = cursor, unchanged = true }
				end

				return { cursor = cursor, session = detail }
			end
		end

		return nil, "session unavailable"
	end

	if method == "reference_browse" or method == "submodule_browse" then
		for _, tree in ipairs(worktrees()) do
			if
				tree.path == params.worktree
				and params.epoch == epoch
				and params.target == require("aero.companion_lifecycle").target(epoch, tree)
			then
				if method == "reference_browse" then
					return require("aero.companion.reference").browse(params)
				end

				local modules = require("aero.submodules")

				if params.refresh == true then
					modules.invalidate(true)
				end

				local function changed()
					require("aero.events").emit("repositories_changed", {})
				end

				local discovered = modules.entries(tree.path, changed)
				local result = { entries = {}, loading = discovered.loading == true, error = discovered.err }

				for _, entry in ipairs(discovered.list or {}) do
					local initialized = modules.initialized(entry.path)
					table.insert(result.entries, { name = entry.name, path = entry.path, initialized = initialized })

					if params.path == entry.path then
						if not initialized then
							return nil, "submodule not initialized"
						end

						local listing = modules.worktrees(entry.path, changed)
						result.loading, result.error = listing.loading == true, listing.err
						result.worktrees = listing.list
						result.workspace = listing.list and listing.list[1] and listing.list[1].path

						if listing.list then
							result.worktrees = vim.tbl_map(function(wt)
								return vim.tbl_extend(
									"force",
									wt,
									{ target = require("aero.companion_lifecycle").target(epoch, wt) }
								)
							end, listing.list)
						end

						return result
					end
				end

				if params.path and params.path ~= "" and not discovered.loading then
					return nil, "submodule unavailable"
				end

				return result
			end
		end

		return nil, "stale worktree or host epoch"
	end

	if method == "prompt_snippets" or method == "articles" then
		if params.epoch ~= epoch then
			return nil, "stale host epoch"
		end

		for _, s in ipairs(sessions) do
			if s.key == params.session and s.chat then
				describe(s)

				if identity(s.chat, identities) ~= params.conversation then
					return nil, "stale conversation"
				end

				if method == "articles" then
					return require("aero.companion.articles").read(s, params.path)
				end

				local snippets = require("aero.prompt_snippets")
				local items, errors = snippets.list(s.worktree)
				local templates = {}

				for _, item in ipairs(items) do
					table.insert(templates, item.prompt)
				end

				return {
					items = items,
					errors = errors,
					context = snippets.context(s.chat, table.concat(templates, "\n")),
				}
			end
		end

		return nil, "session unavailable"
	end

	if
		not lifecycle[method]
		and method ~= "session_assign_board"
		and method ~= "prompt"
		and method ~= "cancel"
		and method ~= "permission"
		and method ~= "reference_update"
		and method ~= "reference_cancel"
		and method ~= "scene_switch"
	then
		return nil, "unknown method"
	end

	local fingerprint, receipt_err, previous = receipts.check(method, params)

	if not fingerprint then
		return nil, receipt_err
	end

	if previous then
		return previous.result, previous.error
	end

	local function finish(result, err)
		receipts.finish(params.operation_id, fingerprint, result, err)

		if lifecycle[method] then
			worktree_cache_at = -5000
		end

		if method:match("^worktree_") and result and result.status == "accepted" then
			require("aero.submodules").invalidate(true)
		end

		return result, err
	end

	if method == "reference_update" or method == "reference_cancel" then
		for _, tree in ipairs(worktrees()) do
			if
				tree.path == params.worktree
				and params.epoch == epoch
				and params.target == require("aero.companion_lifecycle").target(epoch, tree)
			then
				finish({ status = "unknown" })

				if method == "reference_cancel" then
					return finish(
						require("aero.companion.reference_transfer").cancel(params.worktree, params.transfer_id)
					)
				end

				local ok, result, err = pcall(require("aero.companion.reference").update, params, finish)

				if not ok then
					return finish(nil, tostring(result))
				end

				return finish(result, err)
			end
		end

		return finish(nil, "stale worktree or host epoch")
	end

	if method == "scene_switch" then
		if params.epoch ~= epoch then
			return finish(nil, "stale host epoch")
		elseif type(params.scene_id) ~= "string" or not require("aero.scenes").find(params.scene_id) then
			return finish(nil, "scene no longer exists")
		end

		finish({ status = "unknown" })
		local ok, err = require("aero.scenes").switch(params.scene_id)
		return finish(ok and { status = "accepted" } or nil, err)
	end

	local selected

	for _, s in ipairs(sessions) do
		if s.key == params.session then
			selected = s
		end
	end

	local chat = selected and selected.chat

	if method == "session_assign_board" then
		if params.epoch ~= epoch or not selected or params.target ~= identity(selected, identities) then
			return finish(nil, "stale session or host epoch")
		end

		if type(params.board_id) ~= "string" or params.board_id == "" or type(params.replace) ~= "boolean" then
			return finish(nil, "board_id and replacement choice required")
		end

		local workspace = require("aero.repositories").find(params.workspace)

		if not workspace then
			return finish(nil, "workspace unavailable")
		end

		if not chat or params.conversation ~= describe(selected).conversation then
			return finish(nil, "stale conversation")
		end

		finish({ status = "unknown" })
		require("aero.tasks.assignment").assign_board(
			selected,
			workspace,
			params.board_id,
			params.replace,
			function(ok, err)
				finish(
					ok and { status = "accepted" } or nil,
					err and (type(err) == "table" and err.message or tostring(err)) or nil
				)
			end
		)
		local receipt = receipts.get(params.operation_id)
		return receipt.result, receipt.error
	end

	if lifecycle[method] then
		if params.epoch ~= epoch then
			return finish(nil, "stale host epoch")
		end

		if method ~= "session_create" and method:match("^session_") then
			if not selected or params.target ~= identity(selected, identities) then
				return finish(nil, "stale session")
			end
		end

		finish({ status = "unknown" })
		require("aero.companion_lifecycle").run(method, params, sessions, finish)
		worktree_cache_at = -5000
		local receipt = receipts.get(params.operation_id)
		return receipt.result, receipt.error
	end

	if not chat then
		return finish(nil, "session unavailable")
	end

	describe(selected) -- Rotate the generation if the ACP conversation changed in place.

	if identity(chat, identities) ~= params.conversation then
		return finish(nil, "stale conversation")
	end

	if method == "prompt" and type(params.text) == "string" and vim.trim(params.text):match("^/export") then
		local command = vim.trim(params.text)

		if command == "/export" or command == "/export readable" then
			finish({ status = "unknown" })
			local path = require("aero.exports").export(chat, { readable = command == "/export readable" })

			if not path then
				return finish(nil, "could not export log")
			end

			return finish({ status = "accepted", message = "Exported log: " .. path })
		end
	end

	if chat.state == "exited" or not chat.client then
		return finish(nil, "agent unavailable")
	end

	if method == "prompt" then
		return require("aero.companion.prompt").send(chat, selected, params.text, worktrees, finish)
	elseif method == "cancel" then
		finish({ status = "unknown" })
		chat:cancel()
		finish({ status = "accepted" })
	else
		local p = chat.permission

		if not p or identity(p, permissions) ~= params.permission then
			return finish(nil, "stale permission")
		end

		local index

		for i, option in ipairs(p.block.options) do
			if option.optionId == params.option then
				index = i
			end
		end

		if not index then
			return finish(nil, "invalid permission choice")
		end

		finish({ status = "unknown" })
		chat:choose(index)
		finish({ status = "accepted" })
	end

	return receipts.get(params.operation_id).result
end

return M
