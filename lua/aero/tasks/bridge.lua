-- Dedicated newline-framed JSON protocol; never exposes Neovim RPC or eval.
local uv = vim.uv
local M = { protocol_version = 1 }
local server, endpoint, directory
local bindings, clients, queue = {}, {}, {}
local dispatching = false
local max_message, max_queue = 1024 * 1024, 32

local function close(client)
	clients[client] = nil
	if not client:is_closing() then
		client:close()
	end
end

local function send(client, response)
	if not client:is_closing() then
		local text = vim.json.encode(response)
		if #text + 1 > max_message then
			text = vim.json.encode({
				version = M.protocol_version,
				id = response.id,
				error = { code = "INVALID_DOCUMENT", message = "task response exceeds the 1 MiB protocol limit" },
			})
		end
		client:write(text .. "\n")
	end
end

local methods = {
	list_boards = true,
	get_board = true,
	get_ticket = true,
	create_ticket = true,
	create_report = true,
	move_ticket = true,
	update_ticket_body = true,
	update_ticket_metadata = true,
}

local function pump()
	if dispatching then
		return
	end
	dispatching = true
	vim.schedule(function()
		while #queue > 0 do
			local item = table.remove(queue, 1)
			local request, client = item.request, item.client
			local binding = bindings[request.credential]
			local result, err
			if request.version ~= M.protocol_version then
				err = { code = "INVALID_ARGUMENT", message = "incompatible bridge protocol" }
			elseif not binding then
				err = { code = "NOT_FOUND", message = "binding expired or credential invalid" }
			elseif not methods[request.method] then
				err = { code = "INVALID_ARGUMENT", message = "unknown method" }
			elseif vim.fn.getcmdwintype() ~= "" then
				err = { code = "EDITOR_BUSY", message = "close the command window and retry" }
			else
				local ok
				ok, result, err = pcall(require("aero.tasks.operations")[request.method], binding, request.params or {})
				if not ok then
					err, result = { code = "IO_ERROR", message = tostring(result) }, nil
				end
			end
			send(client, { version = M.protocol_version, id = request.id, result = result, error = err })
		end
		dispatching = false
	end)
end

function M.start()
	if server then
		return endpoint
	end
	if uv.os_uname().sysname == "Windows_NT" then
		return nil, "task bridge currently requires Unix-domain sockets"
	end
	directory = vim.fn.tempname()
	local ok, err = uv.fs_mkdir(directory, 448)
	if not ok then
		return nil, err
	end
	endpoint = directory .. "/task.sock"
	if #endpoint > 100 then
		uv.fs_rmdir(directory)
		return nil, "runtime socket path is too long"
	end
	server = uv.new_pipe(false)
	ok, err = server:bind(endpoint)
	if not ok then
		M.stop()
		return nil, err
	end
	uv.fs_chmod(endpoint, 384)
	server:listen(16, function(listen_err)
		if listen_err then
			return
		end
		local client, buffer = uv.new_pipe(false), ""
		server:accept(client)
		clients[client] = true
		client:read_start(function(read_err, chunk)
			if read_err or not chunk then
				close(client)
				return
			end
			buffer = buffer .. chunk
			while buffer:find("\n", 1, true) do
				local at = buffer:find("\n", 1, true)
				if at > max_message then
					close(client)
					return
				end
				local line = buffer:sub(1, at - 1)
				buffer = buffer:sub(at + 1)
				local decoded, request = pcall(vim.json.decode, line)
				if not decoded or type(request) ~= "table" or type(request.credential) ~= "string" then
					close(client)
					return
				end
				if #queue >= max_queue then
					send(client, {
						version = 1,
						id = request.id,
						error = { code = "EDITOR_BUSY", message = "request queue full" },
					})
				else
					table.insert(queue, { client = client, request = request })
					pump()
				end
			end
			if #buffer >= max_message then
				close(client)
			end
		end)
	end)
	return endpoint
end

function M.bind(binding)
	local path, err = M.start()
	if not path then
		return nil, err
	end
	local random, random_err = uv.random(32)
	if not random then
		return nil, random_err
	end
	local credential = (random:gsub(".", function(byte)
		return ("%02x"):format(byte:byte())
	end))
	bindings[credential] = vim.deepcopy(binding)
	return { socket = path, credential = credential, protocol_version = 1 }
end

function M.unbind(credential)
	if bindings[credential] then
		bindings[credential].revoked = true
	end
	bindings[credential] = nil
end

function M.stop()
	for _, binding in pairs(bindings) do
		binding.revoked = true
	end
	bindings, queue = {}, {}
	for client in pairs(clients) do
		close(client)
	end
	if server and not server:is_closing() then
		server:close()
	end
	server = nil
	if endpoint then
		uv.fs_unlink(endpoint)
	end
	if directory then
		uv.fs_rmdir(directory)
	end
	endpoint, directory = nil, nil
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = M.stop })
return M
