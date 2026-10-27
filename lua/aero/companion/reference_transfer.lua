-- Callback-based filesystem work runs on libuv's worker pool, never a recursive
-- synchronous copy on the editor thread. A complete budgeted scan precedes writes.
local M = {}
local uv = vim.uv
local policy = require("aero.companion.reference_policy")
local storage = require("aero.storage")
local active = {}

function M.start(worktree, items, callback, operation_id)
	local directory = require("aero.reference").directory(worktree)

	if active[directory] then
		return nil, "a reference transfer is already running for this worktree"
	end

	local options = vim.deepcopy(policy.options())

	for _, key in ipairs({ "max_entries", "max_bytes", "max_depth", "timeout_ms" }) do
		local value = options[key]

		if value ~= false and (type(value) ~= "number" or value < 1 or value ~= math.floor(value)) then
			return nil, "companion.reference_finder." .. key .. " must be a positive integer or false"
		end
	end

	local job = { created = {}, fds = {}, started = uv.hrtime(), bytes = 0, count = 0, operation_id = operation_id }
	active[directory] = job
	local co

	local function resume(...)
		local ok, err = coroutine.resume(co, ...)

		if not ok then
			active[directory] = nil
			callback(nil, tostring(err))
		end
	end

	local function fs(operation, ...)
		local args = { ... }
		args[#args + 1] = function(err, result)
			vim.schedule(function()
				resume(not err, err or result)
			end)
		end
		operation(unpack(args))
		local ok, result = coroutine.yield()

		if not ok then
			error(tostring(result), 0)
		end

		return result
	end

	local function check()
		if job.cutting then
			return
		end -- completing a verified cut must not strand half-removed sources

		if job.cancelled then
			error("reference transfer cancelled; source files have not been removed", 0)
		end

		if options.timeout_ms and (uv.hrtime() - job.started) / 1e6 > options.timeout_ms then
			error("reference transfer timed out; source files have not been removed", 0)
		end
	end

	local function allowed(path)
		check()
		local ok, err = policy.allowed(path)

		if not ok then
			error(err, 0)
		end
	end

	local function scan(path, depth)
		allowed(path)
		local stat = fs(uv.fs_lstat, path)

		if stat.type == "directory" and options.max_depth and depth > options.max_depth then
			error("reference transfer exceeds max_depth", 0)
		end

		job.count = job.count + 1

		if options.max_entries and job.count > options.max_entries then
			error("reference transfer exceeds max_entries", 0)
		end

		local node = { path = path, stat = stat, children = {} }

		if stat.type == "file" then
			job.bytes = job.bytes + stat.size

			if options.max_bytes and job.bytes > options.max_bytes then
				error("reference transfer exceeds max_bytes", 0)
			end
		elseif stat.type == "directory" then
			local handle = fs(uv.fs_scandir, path)
			while true do
				local name = uv.fs_scandir_next(handle)

				if not name then
					break
				end

				table.insert(node.children, scan(vim.fs.joinpath(path, name), depth + 1))
			end
		elseif stat.type ~= "link" then
			error("unsupported reference source type: " .. path, 0)
		end

		return node
	end

	local function same(node, stat)
		return node.stat.type == stat.type
			and node.stat.dev == stat.dev
			and node.stat.ino == stat.ino
			and node.stat.size == stat.size
			and node.stat.mtime.sec == stat.mtime.sec
			and node.stat.mtime.nsec == stat.mtime.nsec
			and node.stat.ctime.sec == stat.ctime.sec
			and node.stat.ctime.nsec == stat.ctime.nsec
	end

	local function verify(node)
		allowed(node.path)

		if not same(node, fs(uv.fs_lstat, node.path)) then
			error("reference source changed: " .. node.path, 0)
		end
	end

	local function remove(path)
		local stat = fs(uv.fs_lstat, path)

		if stat.type == "directory" then
			local handle = fs(uv.fs_scandir, path)
			while true do
				local name = uv.fs_scandir_next(handle)

				if not name then
					break
				end

				remove(vim.fs.joinpath(path, name))
			end
			fs(uv.fs_rmdir, path)
		else
			fs(uv.fs_unlink, path)
		end
	end

	local function copy(node, destination, top)
		verify(node)

		if node.stat.type == "directory" then
			fs(uv.fs_mkdir, destination, 448) -- exclusive creation; no existing tree is ever reused

			if top then
				table.insert(job.created, destination)
			end

			for _, child in ipairs(node.children) do
				copy(child, vim.fs.joinpath(destination, vim.fs.basename(child.path)))
			end
		elseif node.stat.type == "link" then
			local target = fs(uv.fs_readlink, node.path)
			fs(uv.fs_symlink, target, destination)

			if top then
				table.insert(job.created, destination)
			end
		else
			-- Reserve the destination exclusively BEFORE copying so failed attempts
			-- cannot delete another operation's pre-existing reference file.
			local fd = fs(uv.fs_open, destination, "wx", 384)
			job.fds[fd] = true

			if top then
				table.insert(job.created, destination)
			end

			local source = fs(uv.fs_open, node.path, "r", 0)
			job.fds[source] = true

			if not same(node, fs(uv.fs_fstat, source)) then
				error("reference source changed: " .. node.path, 0)
			end

			local offset = 0
			while offset < node.stat.size do
				check()
				local data = fs(uv.fs_read, source, math.min(1024 * 1024, node.stat.size - offset), offset)

				if #data == 0 then
					error("reference source changed: " .. node.path, 0)
				end

				local written = 0
				while written < #data do
					local count = fs(uv.fs_write, fd, data:sub(written + 1), offset + written)

					if count == 0 then
						error("could not write reference file", 0)
					end

					written = written + count
				end
				offset = offset + #data
			end

			if not same(node, fs(uv.fs_fstat, source)) then
				error("reference source changed: " .. node.path, 0)
			end

			fs(uv.fs_fchmod, fd, node.stat.mode % 512)
			fs(uv.fs_fsync, fd)
			fs(uv.fs_close, source)
			job.fds[source] = nil
			fs(uv.fs_close, fd)
			job.fds[fd] = nil
			verify(node)
		end
	end

	local function verify_tree(node)
		verify(node)

		for _, child in ipairs(node.children) do
			verify_tree(child)
		end
	end

	local function cut(node)
		-- Only remove the scanned entries, never recursively delete an unscanned
		-- replacement or a newly-created child. Copies are retained on cut errors.
		if node.stat.type == "directory" then
			allowed(node.path)
			local stat = fs(uv.fs_lstat, node.path)

			if stat.type ~= "directory" or stat.ino ~= node.stat.ino or stat.dev ~= node.stat.dev then
				error("reference source changed: " .. node.path, 0)
			end

			for _, child in ipairs(node.children) do
				cut(child)
			end

			fs(uv.fs_rmdir, node.path)
		else
			verify(node)
			fs(uv.fs_unlink, node.path)
		end
	end

	co = coroutine.create(function()
		local cutting = false
		local ok, err = pcall(function()
			local plans, names = {}, {}

			for _, item in ipairs(items) do
				local name = vim.fs.basename(item.path)

				if name == "" or name == "." or name == ".." or names[name] then
					error("invalid or duplicate reference item name", 0)
				end

				names[name] = true
				local source = storage.canonical(item.path)

				if source == "/" or source == directory or storage.inside(directory, source) then
					error("reference destination is inside source", 0)
				end

				for _, other in ipairs(items) do
					if
						other ~= item
						and (storage.canonical(other.path) == source or storage.inside(other.path, source))
					then
						error("select a folder or its contents, rather than both", 0)
					end
				end

				table.insert(
					plans,
					{ item = item, node = scan(item.path, 0), destination = vim.fs.joinpath(directory, name) }
				)
			end

			check()
			vim.fn.mkdir(directory, "p", 448)

			for _, plan in ipairs(plans) do
				copy(plan.node, plan.destination, true)
			end

			for _, plan in ipairs(plans) do
				if plan.item.action == "cut" then
					verify_tree(plan.node)
				end
			end

			check()

			if not policy.options().allow_cut then
				for _, plan in ipairs(plans) do
					if plan.item.action == "cut" then
						error("remote reference cutting is disabled", 0)
					end
				end
			end

			cutting, job.cutting = true, true

			for _, plan in ipairs(plans) do
				if plan.item.action == "cut" then
					cut(plan.node)
				end
			end
		end)

		for fd in pairs(job.fds) do
			pcall(fs, uv.fs_close, fd)
		end

		if not ok and not cutting then
			for i = #job.created, 1, -1 do
				pcall(remove, job.created[i])
			end
		end

		active[directory] = nil
		require("aero.events").emit("reference_changed", { worktree = worktree })
		callback(ok and { status = "accepted" } or nil, not ok and tostring(err) or nil)
	end)
	vim.schedule(function()
		resume()
	end)
	return { status = "unknown" }
end

function M.busy(worktree)
	return active[require("aero.reference").directory(worktree)] ~= nil
end

function M.cancel(worktree, operation_id)
	local job = active[require("aero.reference").directory(worktree)]

	if not job or type(operation_id) ~= "string" or job.operation_id ~= operation_id then
		return nil, "no matching reference transfer is running"
	end

	if job.cutting then
		return nil, "transfer is completing its cut; cancellation is no longer available"
	end

	job.cancelled = true
	return {
		status = "accepted",
		message = "Reference cancellation requested. Check the original action receipt for the final outcome.",
	}
end

return M
