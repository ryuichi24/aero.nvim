-- One newline-delimited request per local socket connection. Dispatch runs on the
-- editor thread; this transport owns accepted clients and bounds request size.
local uv = vim.uv
local M = {}

function M.listen(server, dispatch)
	local clients = {}
	server:listen(16, function(err)
		if err then
			return
		end

		local client, buffer, pending = uv.new_pipe(false), "", false
		server:accept(client)
		clients[client] = true

		local function close()
			clients[client] = nil

			if not client:is_closing() then
				client:close()
			end
		end

		client:read_start(function(read_err, chunk)
			if read_err or not chunk then
				close()
				return
			end

			buffer = buffer .. chunk

			if #buffer > 131072 or pending then
				close()
				return
			end

			if not buffer:find("\n", 1, true) then
				return
			end

			pending = true
			vim.schedule(function()
				local ok, request = pcall(vim.json.decode, buffer)
				local result, failure

				if ok and type(request) == "table" then
					local success
					success, result, failure = pcall(dispatch, request.method, request.params)

					if not success then
						result, failure = nil, "host action failed; outcome unknown"
					end
				else
					failure = "invalid request"
				end

				if not client:is_closing() then
					client:write(vim.json.encode({ result = result, error = failure }) .. "\n", close)
				end
			end)
		end)
	end)
	return function()
		for client in pairs(clients) do
			if not client:is_closing() then
				client:close()
			end
		end

		clients = {}
	end
end

return M
