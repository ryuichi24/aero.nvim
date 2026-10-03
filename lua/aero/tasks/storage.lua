local shared = require("aero.storage")
local M = {}
local serial = 0

function M.id(prefix)
	serial = serial + 1
	return prefix
		.. "-"
		.. vim.fn.sha256(tostring(vim.uv.hrtime()) .. ":" .. vim.fn.getpid() .. ":" .. serial):sub(1, 20)
end

function M.directory(ws)
	local root = shared.canonical(type(ws) == "table" and ws.root or ws)
	local setting = require("aero.config").options.tasks.directory
	if setting == "worktree" then
		return vim.fs.joinpath(root, ".aero", "tasks")
	end
	if type(setting) == "function" then
		local ok, result = pcall(setting, root)
		if not ok then
			return nil, tostring(result)
		end
		if type(result) ~= "string" or result == "" then
			return nil, "tasks.directory must return a directory"
		end
		result = vim.fn.expand(result)
		return shared.canonical(vim.startswith(result, "/") and result or vim.fs.joinpath(root, result))
	end
	if type(setting) ~= "string" or setting == "" then
		return nil, "invalid tasks.directory"
	end
	local base = setting == "data" and vim.fs.joinpath(vim.fn.stdpath("data"), "Aero", "workspaces")
		or vim.fn.expand(setting)
	if not vim.startswith(base, "/") then
		return shared.canonical(vim.fs.joinpath(root, base))
	end
	return vim.fs.joinpath(shared.canonical(base), shared.folder(root), "tasks")
end

function M.read(path)
	local f, err = io.open(path, "rb")
	if not f then
		return nil, err
	end
	local text = f:read("*a")
	f:close()
	return text
end

function M.lines(text)
	local lines = vim.split(text, "\n", { plain = true })
	if lines[#lines] == "" then
		table.remove(lines)
	end
	for i, line in ipairs(lines) do
		lines[i] = line:gsub("\r$", "")
	end
	return lines
end

function M.text(lines, original)
	local newline = original and original:find("\r\n", 1, true) and "\r\n" or "\n"
	return table.concat(lines, newline) .. ((not original or original:sub(-1) == "\n") and newline or "")
end

function M.board_path(ws, path)
	local directory, err = M.directory(ws)
	if not directory then
		return nil, err
	end
	local folder = vim.fs.dirname(path)
	local stat = vim.uv.fs_lstat(folder)
	if
		not stat
		or stat.type ~= "directory"
		or shared.canonical(vim.fs.dirname(folder)) ~= shared.canonical(directory)
	then
		return nil, "board must belong to an immediate, non-symlinked folder in this workspace's task directory"
	end
	if vim.fs.basename(path) ~= "board.md" then
		return nil, "invalid board filename"
	end
	local file = vim.uv.fs_lstat(path)
	if file and file.type ~= "file" then
		return nil, "board source must be a regular file"
	end
	return shared.canonical(path)
end

function M.ticket_path(board, destination)
	if type(destination) ~= "string" or destination:find("%c") or destination == "" then
		return nil, "invalid ticket destination"
	end
	local tickets = vim.fs.joinpath(vim.fs.dirname(board), "tickets")
	local stat = vim.uv.fs_lstat(tickets)
	if stat and stat.type ~= "directory" then
		return nil, "tickets directory must not be a symlink"
	end
	local path = vim.fs.joinpath(vim.fs.dirname(board), destination)
	if not shared.inside(path, tickets) or shared.canonical(vim.fs.dirname(path)) ~= shared.canonical(tickets) then
		return nil, "ticket reference escapes this board's tickets directory"
	end
	if not path:match("%.md$") then
		return nil, "ticket reference must be Markdown"
	end
	local file = vim.uv.fs_lstat(path)
	if file and file.type ~= "file" then
		return nil, "ticket source must be a regular file (no symlink aliases)"
	end
	return shared.canonical(path)
end

function M.list(directory, kind)
	local scan, err, code = vim.uv.fs_scandir(directory)
	if not scan then
		return {}, code ~= "ENOENT" and err or nil
	end
	local paths = {}
	while true do
		local name, entry_kind = vim.uv.fs_scandir_next(scan)
		if not name then
			break
		end
		if entry_kind == kind then
			table.insert(paths, vim.fs.joinpath(directory, name))
		end
	end
	table.sort(paths)
	return paths
end

function M.unmodified(path)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(buf)
		if name ~= "" and shared.canonical(name) == shared.canonical(path) and vim.bo[buf].modified then
			return nil, "unsaved edits in " .. path .. "; save or discard them before changing tasks"
		end
	end
	return true
end

function M.refresh(path)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(buf)
		if
			vim.api.nvim_buf_is_loaded(buf)
			and name ~= ""
			and shared.canonical(name) == shared.canonical(path)
			and not vim.bo[buf].modified
		then
			vim.api.nvim_buf_call(buf, function()
				vim.cmd("checktime")
			end)
		end
	end
end

function M.create(path, text)
	local ok, err = M.unmodified(path)
	if not ok then
		return nil, err
	end
	local fd, open_err = vim.uv.fs_open(path, "wx", 420)
	if not fd then
		return nil, open_err
	end
	local written, write_err = vim.uv.fs_write(fd, text, 0)
	vim.uv.fs_close(fd)
	if written ~= #text then
		return nil, write_err or "incomplete file write"
	end
	return true
end

function M.write(path, original, text)
	local ok, err = M.unmodified(path)
	if not ok then
		return nil, err
	end
	local current = M.read(path)
	if current ~= original then
		return nil, "task file changed externally; refresh and try again"
	end
	local tmp = path .. "." .. M.id("tmp")
	ok, err = M.create(tmp, text)
	if not ok then
		vim.uv.fs_unlink(tmp)
		return nil, err
	end
	ok, err = M.unmodified(path)
	if not ok or M.read(path) ~= original then
		vim.uv.fs_unlink(tmp)
		return nil, err or "task file changed before commit; refresh and try again"
	end
	local stat = vim.uv.fs_stat(path)
	if stat then
		vim.uv.fs_chmod(tmp, stat.mode % 512)
	end
	ok, err = vim.uv.fs_rename(tmp, path)
	if not ok then
		vim.uv.fs_unlink(tmp)
		return nil, err
	end
	M.refresh(path)
	return true
end

-- A same-host dead owner can be recovered; live or remote owners are never stolen.
function M.with_lock(ws, callback)
	local directory, err = M.directory(ws)
	if not directory then
		return nil, err
	end
	local made, mkdir_err = pcall(vim.fn.mkdir, directory, "p")
	if not made then
		return nil, tostring(mkdir_err)
	end
	local path = vim.fs.joinpath(directory, ".aero-tasks.lock")
	local token = M.id("lock")
	local owner = {
		pid = vim.fn.getpid(),
		host = vim.uv.os_gethostname(),
		token = token,
		created_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
	}
	local fd, open_err, open_code = vim.uv.fs_open(path, "wx", 384)
	if not fd then
		if open_code ~= "EEXIST" then
			return nil, "could not acquire workspace task lock: " .. tostring(open_err)
		end
		local original = M.read(path)
		local decoded, previous = pcall(vim.json.decode, original or "")
		if
			decoded
			and type(previous) == "table"
			and previous.host == owner.host
			and type(previous.pid) == "number"
			and previous.pid > 0
			and previous.pid <= 2147483647
			and previous.pid % 1 == 0
		then
			local alive, _, code = vim.uv.kill(previous.pid, 0)
			if not alive and code == "ESRCH" and M.read(path) == original then
				vim.uv.fs_unlink(path)
				fd = vim.uv.fs_open(path, "wx", 384)
			end
		end
	end
	if not fd then
		return nil, "workspace task lock is held: " .. path .. " (remove only after verifying its owner is gone)"
	end
	local lock_text = vim.json.encode(owner)
	local written, write_err = vim.uv.fs_write(fd, lock_text, 0)
	vim.uv.fs_close(fd)
	if not written then
		vim.uv.fs_unlink(path)
		return nil, write_err
	end
	local function pack(...)
		return { n = select("#", ...), ... }
	end
	local results = pack(pcall(callback))
	if M.read(path) == lock_text then
		vim.uv.fs_unlink(path)
	end
	if not results[1] then
		return nil, tostring(results[2])
	end
	return unpack(results, 2, results.n)
end

return M
