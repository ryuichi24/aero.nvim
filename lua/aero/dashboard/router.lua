-- Semantic sidebar actions. View ownership and expansion changes are supplied by the dashboard.
local M = {}
local open = {
	scene = function()
		require("aero.scenes").open()
	end,
	session = function(item, how, view)
		if item.knowledge then
			return require("aero.knowledge.agent").show(item.session)
		elseif item.general then
			return require("aero.general").show(item.session)
		end

		return view.open_session(item.session, how or "default")
	end,
	knowledge_manage = function()
		require("aero.knowledge").open()
	end,
	knowledge_note = function(item)
		vim.ui.select({ "Open", "Edit tag" }, { prompt = item.note.name }, function(choice)
			if choice == "Open" then
				require("aero.knowledge.notes").edit(item.space.id, item.note.id)
			elseif choice == "Edit tag" then
				require("aero.knowledge.metadata").edit_tags(item.space.id, item.note.id, "notes")
			end
		end)
	end,
	knowledge_source = function(item)
		require("aero.knowledge").browse_space(item.space, "Browse sources", item.source and item.source.id)
	end,
	knowledge_section = function(item)
		require("aero.knowledge").browse_space(
			item.space,
			item.section == "Sources" and "Browse sources" or item.section
		)
	end,
	general_new = function()
		require("aero.general").new()
	end,
	general_history = function()
		require("aero.general").history()
	end,
	board = function(item)
		require("aero.tasks.view").open(item.ws, item.board.path)
	end,
	board_new = function(item)
		require("aero.tasks.ui").new_board(item.ws)
	end,
	tickets_removed = function(item)
		require("aero.tasks.ui").removed(item.ws)
	end,
	report = function(item, how, view)
		view.open_report(item, how)
	end,
	reference_item = function(item, how, view)
		if item.reference.kind == "directory" then
			view.toggle()
		else
			view.open_report(vim.tbl_extend("force", item, { report = item.reference }), how)
		end
	end,
	reference_new = function(item)
		require("aero.reference").open(item.wt.path)
	end,
	report_new = function(item, _, view)
		view.new_report(item)
	end,
	reading_list = function(item, _, view)
		view.open_reading(item, item.kind == "reading_new")
	end,
}
open.export, open.reading_new = open.report, open.reading_list

function M.open(item, how, view)
	if not item then
		return
	end

	if item.expanded ~= nil and item.kind:match("^knowledge_") and item.kind ~= "knowledge_manage" then
		return view.toggle()
	end

	local handler = open[item.kind]

	if handler then
		return handler(item, how, view)
	end

	return view.toggle()
end

function M.add(item, view)
	if not item then
		return view.add_workspace()
	end

	if item.kind == "scene" then
		require("aero.scenes").command({ "new" })
	elseif item.general or item.kind == "general_group" then
		require("aero.general").new()
	elseif item.kind == "knowledge_group" or item.kind == "knowledge_manage" then
		require("aero.knowledge").open()
	elseif item.kind == "knowledge_collection" then
		require("aero.knowledge").new_space(item.collection.id)
	elseif item.kind == "knowledge_source" or item.kind == "knowledge_folder" then
		local directory = item.directory
		local folder_id = item.folder and item.folder.id or item.source and item.source.folder_id

		if item.source then
			directory = (item.source.relative_path or item.source.name):match("^(.*)/[^/]+$")
		end

		require("aero.knowledge").add_files(item.space.id, { directory = directory, folder_id = folder_id })
	elseif item.kind == "knowledge_note" then
		require("aero.knowledge").browse_space(item.space, "New note")
	elseif item.kind == "knowledge_section" and item.section ~= "Sessions" then
		require("aero.knowledge").browse_space(item.space, ({ Sources = "Add file", Notes = "New note" })[item.section])
	elseif item.space or item.collection or item.knowledge then
		local scope = item.space and { space_id = item.space.id }
			or item.collection and { collection_id = item.collection.id }
			or require("aero.knowledge.agent").scope(item.session)
		require("aero.knowledge.agent").new(scope)
	elseif item.kind == "workspace_group" then
		view.add_workspace()
	elseif
		item.kind == "boards"
		or item.kind == "board"
		or item.kind == "board_new"
		or item.kind == "tickets_removed"
	then
		require("aero.tasks.ui").new_board(item.ws)
	elseif item.kind == "workspace" or item.kind == "submodule" then
		view.add_worktree(item.ws)
	elseif item.kind == "reports" or item.kind == "report" or item.kind == "report_new" then
		view.new_report(item)
	elseif item.kind == "reading" or item.kind == "reading_list" or item.kind == "reading_new" then
		view.open_reading(item, true)
	elseif item.kind == "reference" or item.kind == "reference_item" or item.kind == "reference_new" then
		require("aero.reference").open(item.wt.path)
	else
		view.choose_agent(item)
	end
end

return M
