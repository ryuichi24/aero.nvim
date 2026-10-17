-- Host-epoch operation receipts. Capacity exhaustion refuses new actions rather
-- than evicting receipts and allowing an identical retry to execute twice.
local M = {}

function M.new()
	local entries, count = {}, 0
	local registry = {}
	function registry.get(id)
		return entries[id]
	end
	function registry.check(method, params)
		if type(params.operation_id) ~= "string" or #params.operation_id < 16 or #params.operation_id > 128 then
			return nil, "operation_id required (16-128 characters)"
		end
		local fingerprint = vim.json.encode({
			method,
			params.session,
			params.conversation,
			params.text or false,
			params.permission or false,
			params.option or false,
			params.epoch or false,
			params.target or false,
			params.workspace or false,
			params.worktree or false,
			params.agent or false,
			params.name or false,
			params.branch or false,
			params.force or false,
			params.board_id or false,
			params.replace or false,
			params.reference_action or false,
			params.path or false,
			params.items or false,
			params.transfer_id or false,
		})
		local previous = entries[params.operation_id]
		if previous then
			if previous.fingerprint ~= fingerprint then
				return nil, "operation_id reused with different arguments"
			end
			return fingerprint, nil, previous
		end
		if count >= 10000 then
			return nil, "operation receipt capacity reached"
		end
		return fingerprint
	end
	function registry.finish(id, fingerprint, result, err)
		if not entries[id] then
			count = count + 1
		end
		entries[id] = { fingerprint = fingerprint, result = result, error = err }
		return result, err
	end
	return registry
end

return M
