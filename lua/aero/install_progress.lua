-- Keep scheduled UI updates running while waiting for installer subprocesses.
local M = {}

function M.wait(cmd, timeout, opts)
	opts = opts or { text = true }
	local result
	local process = vim.system(cmd, opts, function(value)
		result = value
	end)

	if vim.wait(timeout, function()
		return result ~= nil
	end, 50) then
		return result
	end

	return process:wait(0)
end

function M.download(url, path, progress, stage)
	progress.update(stage, 0, "Connecting…")
	local output, pending = {}, ""
	local result = M.wait(
		{
			"curl",
			"--fail",
			"--location",
			"--progress-bar",
			"--show-error",
			"--proto",
			"=https",
			"--proto-redir",
			"=https",
			"--max-time",
			"120",
			"--output",
			path,
			url,
		},
		125000,
		{
			text = true,
			stderr = function(_, data)
				if not data then
					return
				end

				output[#output + 1] = data
				pending = pending .. data
				local percent

				for value in pending:gmatch("([%d%.]+)%%") do
					percent = tonumber(value)
				end

				pending = pending:match("[^\r\n]*$") or ""

				if percent then
					vim.schedule(function()
						progress.update(stage, 0, ("%.1f%% downloaded"):format(percent))
					end)
				else
					-- Some servers omit Content-Length, so curl cannot report a percentage.
					local stat = vim.uv.fs_stat(path)

					if stat and stat.size > 0 then
						local bytes = stat.size
						vim.schedule(function()
							progress.update(stage, bytes, "Downloading")
						end)
					end
				end
			end,
		}
	)

	if result.code ~= 0 then
		local message = table.concat(output):match("curl: ([^\r\n]+)")
		return nil, message or vim.trim(result.stderr or table.concat(output))
	end

	progress.update(stage, 0, "100% downloaded")
	return true
end

return M
