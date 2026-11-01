-- All agent operations inherit a host-owned scope, never a scope supplied by the agent.
local store = require("aero.knowledge.store")
local research = require("aero.knowledge.research")
local response = require("aero.knowledge.response")
local M = {}

function M.call(binding, params, callback)
	assert(binding.knowledge_scope and not binding.revoked, "knowledge binding is unavailable")
	local scope = vim.deepcopy(binding.knowledge_scope)

	for _, session in ipairs(require("aero.session").all()) do
		if session.key == binding.session_key then
			scope = require("aero.knowledge.agent").scope(session) or scope
		end
	end

	local selected_sources = scope.source_ids

	if params.source_ids then
		for _, source_id in ipairs(params.source_ids) do
			assert(
				not selected_sources or vim.tbl_contains(selected_sources, source_id),
				"requested source is outside the selected source set"
			)
		end

		scope.source_ids = params.source_ids
	end

	local data = store.read()
	local spaces = store.scope(data, scope)
	local allowed_spaces = {}

	for _, space in ipairs(spaces) do
		allowed_spaces[space.id] = true
	end

	if params.action == "list" then
		local selected = vim.deepcopy(spaces)

		for _, space in ipairs(selected) do
			space.sources = vim.tbl_filter(function(source)
				return (not scope.source_ids or vim.tbl_contains(scope.source_ids, source.id))
					and (not params.tag or vim.tbl_contains(source.tags or {}, params.tag))
			end, space.sources)
			space.notes = vim.tbl_filter(function(note)
				if params.tag and not vim.tbl_contains(note.tags or {}, params.tag) then
					return false
				end

				if scope.source_ids then
					if #note.citations == 0 then
						return false
					end

					for _, citation in ipairs(note.citations) do
						if not vim.tbl_contains(scope.source_ids, citation.source_id) then
							return false
						end
					end
				end

				return true
			end, space.notes)
		end

		local offset = math.max(0, math.floor(tonumber(params.offset) or 0))
		local limit = math.min(math.max(math.floor(tonumber(params.limit) or 20), 1), 100)
		local total = 0
		local summaries = {}

		for _, space in ipairs(selected) do
			local summary = { id = space.id, name = space.name, sources = {}, notes = {} }

			for _, kind in ipairs({ "sources", "notes" }) do
				for _, item in ipairs(space[kind]) do
					total = total + 1

					if total > offset and total <= offset + limit then
						table.insert(summary[kind], {
							id = item.id,
							name = item.name,
							status = item.status,
							version = item.version,
							revision = item.revision,
							tags = item.tags,
						})
					end
				end
			end

			if #summary.sources > 0 or #summary.notes > 0 or (#selected == 1 and total == 0) then
				table.insert(summaries, summary)
			end
		end

		return {
			scope = scope,
			spaces = summaries,
			total_items = total,
			next_offset = offset + limit < total and offset + limit or nil,
		}
	elseif params.action == "jobs" then
		return vim.tbl_filter(function(job)
			return allowed_spaces[job.space_id] and (not params.id or job.id == params.id)
		end, data.jobs)
	elseif params.action == "cancel_job" or params.action == "retry_job" then
		local job = store.find(data.jobs, params.id)
		assert(allowed_spaces[job.space_id], "job is outside this scope")

		if params.action == "cancel_job" then
			return require("aero.knowledge.ingest").cancel(job.id)
		end

		assert(job.status == "failed" or job.status == "cancelled", "only failed or cancelled jobs can be retried")
		return require("aero.knowledge.ingest").start(job.space_id, job.source_id)
	elseif params.action == "pin_note" then
		assert(scope.space_id, "pin notes in a space session")
		return require("aero.knowledge.notes").pin(scope.space_id, params.id, params.pinned)
	elseif params.action == "search" then
		local limit = math.min(math.max(math.floor(tonumber(params.limit) or 5), 1), 20)

		if callback and #require("aero.config").options.knowledge.embedding_command > 0 then
			research.search_async(scope, params.query, limit, function(result, err)
				callback(result and response.search(result, params.query), err)
			end)
			return { pending = true }
		end

		return response.search(research.search(scope, params.query, limit), params.query)
	elseif params.action == "read" then
		local first = math.max(tonumber(params.first) or 1, 1)
		local last = math.min(tonumber(params.last) or first, first + 9)
		return response.read(research.read(scope, params.source_id, first, last, params.version), params.offset)
	elseif params.action == "read_note" then
		for _, space in ipairs(spaces) do
			for _, note in ipairs(space.notes) do
				if note.id == params.id then
					if scope.source_ids then
						assert(#note.citations > 0, "this note has no citations within the selected source set")

						for _, citation in ipairs(note.citations) do
							assert(
								vim.tbl_contains(scope.source_ids, citation.source_id),
								"note evidence is outside the selected source set"
							)
						end
					end

					local body, next_offset, total = response.window(
						table.concat(vim.fn.readfile(store.directory() .. "/" .. note.path), "\n"),
						params.offset,
						12000
					)
					return {
						note = {
							id = note.id,
							name = note.name,
							revision = note.revision,
							tags = note.tags,
							citations = note.citations,
						},
						body = body,
						next_offset = next_offset,
						total_chars = total,
						stale = require("aero.knowledge.notes").stale(data, note.citations),
					}
				end
			end
		end

		error("note is outside the selected scope")
	elseif params.action == "table" then
		local dataset = research.table(scope, params.source_id, params.table_name)
		local first = math.max(1, math.floor(tonumber(params.first) or 1))
		local last = math.min(tonumber(params.last) or first + 19, first + 99, #dataset.rows)
		assert(first <= #dataset.rows or (#dataset.rows == 0 and first == 1), "requested row is unavailable")
		assert(last == math.floor(last) and (last >= first or #dataset.rows == 0), "invalid table row range")
		local result = { name = dataset.name, rows = {}, first_row = first, total_rows = #dataset.rows }
		local budget = 12000

		for index = first, last do
			local encoded = vim.json.encode(dataset.rows[index])

			if vim.fn.strchars(encoded) > budget or (index == first and (params.offset or 0) > 0) then
				result.next_row = index

				if #result.rows == 0 then
					local fragment, next_offset = response.window(encoded, params.offset, budget)
					result.row_fragment, result.fragment_row = fragment, index
					result.next_offset = next_offset
					result.next_row = next_offset and index or (index < #dataset.rows and index + 1 or nil)
				end

				return result
			end

			result.rows[#result.rows + 1] = dataset.rows[index]
			budget = budget - vim.fn.strchars(encoded)
		end

		result.next_row = last < #dataset.rows and last + 1 or nil
		return result
	elseif params.action == "aggregate" then
		local dataset = research.table(scope, params.source_id, params.table_name)
		local evidence = research.read(scope, params.source_id, 1, 1)
		local column = assert(tonumber(params.column), "column is one-based")
		assert(column >= 1 and column == math.floor(column), "column is one-based")
		local values, total = {}, 0
		local first, last =
			math.max(tonumber(params.first) or 2, 1), math.min(tonumber(params.last) or #dataset.rows, #dataset.rows)

		for row = first, last do
			local value = tonumber(dataset.rows[row][column])

			if value and value == value and value ~= math.huge and value ~= -math.huge then
				total = total + value
				table.insert(values, value)
			end
		end

		assert(#values > 0, "selected range has no numeric values")
		table.sort(values)
		return {
			count = #values,
			sum = total,
			mean = total / #values,
			min = values[1],
			max = values[#values],
			source_id = params.source_id,
			table_name = params.table_name,
			column = column,
			first_row = first,
			last_row = last,
			nonnumeric_cells = last - first + 1 - #values,
			version = evidence.version,
		}
	elseif params.action == "save_note" then
		assert(scope.space_id, "save notes in a space session")

		for _, citation in ipairs(params.citations or {}) do
			research.read(scope, citation.source_id, citation.chunk, citation.chunk)
		end

		return require("aero.knowledge.notes").save(
			scope.space_id,
			params.title,
			params.body,
			params.citations,
			params.id,
			binding.session_key,
			params.revision
		)
	end

	error("unknown knowledge action")
end

return M
