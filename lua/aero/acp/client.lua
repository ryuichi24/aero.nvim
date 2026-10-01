-- Minimal JSON-RPC 2.0 client for the Agent Client Protocol over stdio (newline-delimited JSON).
---@class aero.acp.Client
---@field proc vim.SystemObj
---@field closed boolean
local Client = {}
Client.__index = Client

---@class aero.acp.ClientOpts
---@field cwd string
---@field env? table<string, string>
---@field on_request fun(method: string, params: table, respond: fun(result: any, err?: table))
---@field on_notification fun(method: string, params: table)
---@field on_exit fun(code: integer, stderr: string)

---@param cmd string[]
---@param opts aero.acp.ClientOpts
---@return aero.acp.Client|nil, string|nil
function Client.spawn(cmd, opts)
	local self =
		setmetatable({ next_id = 0, pending = {}, partial = "", stderr = {}, closed = false, opts = opts }, Client)
	local ok, proc = pcall(vim.system, cmd, {
		cwd = opts.cwd,
		env = opts.env,
		stdin = true,
		text = true,
		stdout = function(_, data)
			if data then
				vim.schedule(function()
					self:_feed(data)
				end)
			end
		end,
		stderr = function(_, data)
			if data then
				table.insert(self.stderr, data)
			end
		end,
	}, function(r)
		vim.schedule(function()
			self.closed = true
			local pending = self.pending
			self.pending = {}
			for _, cb in pairs(pending) do
				cb({ code = -32000, message = "agent process exited" })
			end
			opts.on_exit(r.code, table.concat(self.stderr))
		end)
	end)
	if not ok then
		return nil, tostring(proc)
	end
	self.proc = proc
	return self
end

function Client:_send(msg)
	if self.closed then
		return
	end
	msg.jsonrpc = "2.0"
	pcall(self.proc.write, self.proc, vim.json.encode(msg) .. "\n")
end

function Client:_feed(data)
	self.partial = self.partial .. data
	while true do
		local nl = self.partial:find("\n", 1, true)
		if not nl then
			return
		end
		local line = self.partial:sub(1, nl - 1)
		self.partial = self.partial:sub(nl + 1)
		if line:match("%S") then
			local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
			if ok and type(msg) == "table" then
				self:_dispatch(msg)
			end
		end
	end
end

function Client:_dispatch(msg)
	if msg.method and msg.id ~= nil then
		local id, answered = msg.id, false
		self.opts.on_request(msg.method, msg.params or {}, function(result, err)
			if answered then
				return
			end
			answered = true
			if err then
				self:_send({ id = id, error = err })
			else
				self:_send({ id = id, result = result == nil and vim.NIL or result })
			end
		end)
	elseif msg.method then
		self.opts.on_notification(msg.method, msg.params or {})
	elseif msg.id ~= nil then
		local cb = self.pending[msg.id]
		self.pending[msg.id] = nil
		if cb then
			cb(msg.error, msg.result)
		end
	end
end

---@param cb fun(err: table|nil, result: any)
function Client:request(method, params, cb)
	if self.closed then
		return cb({ code = -32000, message = "agent process exited" })
	end
	self.next_id = self.next_id + 1
	self.pending[self.next_id] = cb
	self:_send({ id = self.next_id, method = method, params = params })
end

function Client:notify(method, params)
	self:_send({ method = method, params = params })
end

function Client:stop()
	if not self.closed then
		pcall(self.proc.kill, self.proc, 15)
	end
end

return Client
