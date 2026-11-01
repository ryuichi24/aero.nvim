-- Durable, bounded extraction queue. Interrupted work remains explicitly retryable.
local store = require("aero.knowledge.store")
local M = {}
local running, queue, count = {}, {}, 0
local drain

local function launch(work)
	local job_id = work.job.id
	local started = store.update(function(data)
		local job = store.find(data.jobs, job_id)

		if job.status ~= "queued" then
			return false
		end

		job.status, job.stage = "processing", "extracting"
		return job
	end)

	if not started then
		return
	end

	count = count + 1
	local function complete(result)
		vim.schedule(function()
			running[job_id], count = nil, count - 1
			local ok, document = pcall(vim.json.decode, result.stdout or "")
			local success = result.code == 0 and ok and type(document) == "table"
			local saved, failure = store.update(function(data)
				local job = store.find(data.jobs, job_id)

				if job.status == "cancelled" then
					return job
				end

				local source = store.find(store.find(data.spaces, job.space_id).sources, job.source_id)
				job.status, job.stage = success and "ready" or "failed", "finished"
				job.finished_at = os.time()
				job.error = not success and vim.trim(result.stderr or "Extraction failed") or nil
				source.status = success and (#document.issues > 0 and "ready_with_warnings" or "ready")
					or "needs_attention"
				source.error = job.error

				if success then
					local relative = "cache/" .. source.id .. "/" .. document.version .. ".json"
					store.atomic(store.directory() .. "/" .. relative, vim.json.encode(document))
					source.version, source.extraction = document.version, relative
					source.issues, source.indexed_at = document.issues, os.time()
				end

				return job
			end)

			if not saved then
				vim.notify("Aero knowledge: " .. tostring(failure), vim.log.levels.ERROR)
			end

			drain()
		end)
	end

	local config = require("aero.config").options.knowledge
	local ok, process = pcall(function()
		local executable, err = store.executable()
		assert(executable, err)
		return vim.system({
			executable,
			"extract",
			store.directory() .. "/" .. work.source.path,
			work.source.name,
		}, {
			text = true,
			timeout = 180000,
			detach = true,
			stdin = vim.json.encode({ embedding_command = config.embedding_command, extractors = config.extractors }),
		}, complete)
	end)

	if ok then
		running[job_id] = process
	else
		complete({ code = 1, stderr = tostring(process) })
	end
end

drain = function()
	local limit = math.max(tonumber(require("aero.config").options.knowledge.ingest_concurrency) or 2, 1)
	while count < limit and #queue > 0 do
		launch(table.remove(queue, 1))
	end
end

function M.start(space_id, source_id)
	local work, err = store.update(function(data)
		local space = store.find(data.spaces, space_id)
		local source = store.find(space.sources, source_id)

		for _, job in ipairs(data.jobs) do
			assert(
				not (job.source_id == source_id and (job.status == "processing" or job.status == "queued")),
				"source is already processing; cancel interrupted work before retrying"
			)
		end

		local job = {
			id = store.id(),
			kind = "ingest",
			space_id = space_id,
			source_id = source_id,
			status = "queued",
			stage = "queued",
			started_at = os.time(),
			owner_pid = vim.fn.getpid(),
		}
		source.status = "processing"
		table.insert(data.jobs, job)
		return { job = job, source = vim.deepcopy(source) }
	end)

	if not work then
		return nil, err
	end

	table.insert(queue, work)
	drain()
	return work.job
end

function M.cancel(job_id)
	local item, err = store.update(function(data)
		local job = store.find(data.jobs, job_id)
		assert(job.kind == "ingest" and (job.status == "processing" or job.status == "queued"), "job is not processing")
		job.status = "cancelled"
		local source = store.find(store.find(data.spaces, job.space_id).sources, job.source_id)
		source.status, source.error = "needs_attention", "Extraction cancelled; retry to index this source"
		return job
	end)

	if item then
		queue = vim.tbl_filter(function(work)
			return work.job.id ~= job_id
		end, queue)

		if running[job_id] then
			pcall(vim.uv.kill, -running[job_id].pid, 15)
			running[job_id]:kill(15)
		end
	end

	return item, err
end

function M.recover()
	local data = store.catalog()

	for _, job in ipairs(data and data.jobs or {}) do
		if
			job.kind == "ingest"
			and (job.status == "processing" or job.status == "queued")
			and job.owner_pid
			and not vim.uv.kill(job.owner_pid, 0)
		then
			M.cancel(job.id)
		end
	end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		local ids = vim.tbl_keys(running)

		for _, work in ipairs(queue) do
			table.insert(ids, work.job.id)
		end

		for _, job_id in ipairs(ids) do
			M.cancel(job_id)
		end
	end,
})
return M
