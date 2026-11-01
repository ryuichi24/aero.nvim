-- Knowledge inspection shares the middle reader without replacing side panels.
vim.opt.rtp:prepend(vim.fn.getcwd())
local api = vim.api
local root = vim.fn.tempname()
vim.fn.mkdir(root, "p")
require("aero.config").setup({
	state_file = root .. "/state.json",
	companion = { auto_start = false },
	animation = false,
})
local reader = require("aero.reader")
reader.setup()
vim.o.columns, vim.o.lines = 180, 60
local middle = api.nvim_get_current_win()
local original = api.nvim_get_current_buf()
api.nvim_buf_set_lines(original, 0, -1, false, { "Workspace source" })
vim.t.aero_worktree = root
reader.attach(middle, "source")
reader.select("reports")
local report = api.nvim_get_current_buf()
api.nvim_buf_set_lines(report, 0, -1, false, { "Unsaved report", "Report cursor" })
api.nvim_win_set_cursor(middle, { 2, 0 })
local sidebar_buf = api.nvim_create_buf(false, true)
vim.bo[sidebar_buf].filetype = "Aero"
local sidebar = api.nvim_open_win(sidebar_buf, false, { split = "left", win = middle, width = 25 })
local chat_buf = api.nvim_create_buf(false, true)
vim.b[chat_buf].aero_chat_key = "knowledge-reader-test"
local chat = api.nvim_open_win(chat_buf, false, { split = "right", win = middle, width = 40 })
require("aero.navigation").set_dashboard({ state = { win = sidebar, target = middle } })
local knowledge = require("aero.knowledge")
local collection = assert(knowledge.create_collection("Test"))
local space = assert(knowledge.create_space(collection.id, "Research"))
local store = require("aero.knowledge.store")
local chunks = {}

for i = 1, 120 do
	chunks[i] = { text = "Evidence " .. i, location = { page = i } }
end

store.atomic(
	store.directory() .. "/one.json",
	vim.json.encode({ version = "one", chunks = chunks, tables = {}, issues = {} })
)
store.atomic(
	store.directory() .. "/two.json",
	vim.json.encode({
		version = "two",
		chunks = { { text = "Other evidence", location = {} } },
		tables = {},
		issues = {},
	})
)

assert(store.update(function(data)
	for _, id in ipairs({ "abc", "def" }) do
		table.insert(data.spaces[1].sources, {
			id = id,
			name = id .. ".txt",
			path = "spaces/" .. space.id .. "/sources/" .. id,
			status = "ready",
			extraction = id == "abc" and "one.json" or "two.json",
		})
	end

	return true
end))

api.nvim_set_current_win(sidebar)
knowledge.browse_space(space, "Browse sources", "abc", "View extracted content")
local content = api.nvim_get_current_buf()

assert(api.nvim_get_current_win() == middle)
assert(#api.nvim_tabpage_list_wins(0) == 3)
assert(api.nvim_win_get_buf(sidebar) == sidebar_buf and api.nvim_win_get_buf(chat) == chat_buf)
assert(vim.wo[middle].winbar:find("Extracted content", 1, true))
assert(vim.wo[middle].winbar:find("Metadata", 1, true))
assert(not vim.wo[middle].winbar:find("Exported logs", 1, true))
assert(vim.bo[content].readonly and not vim.bo[content].modifiable)

api.nvim_win_set_cursor(middle, { 80, 0 })
vim.cmd("normal! zt")
local content_view = vim.fn.winsaveview()
_G.AeroReaderClick(2)
local metadata = api.nvim_get_current_buf()

assert(metadata ~= content and reader.active() == "metadata")
assert(vim.bo[metadata].filetype == "lua")
assert(table.concat(api.nvim_buf_get_lines(metadata, 0, -1, false), "\n"):find('name = "abc.txt"', 1, true))
assert(#api.nvim_tabpage_list_wins(0) == 3)

_G.AeroReaderClick(1)

assert(api.nvim_get_current_buf() == content)
assert(api.nvim_win_get_cursor(middle)[1] == 80)
assert(vim.fn.winsaveview().topline == content_view.topline)

knowledge.browse_space(space, "Browse sources", "def", "Extraction details")
reader.select("content")

assert(table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Other evidence", 1, true))

knowledge.browse_space(space, "Browse sources", "abc", "View extracted content")

assert(api.nvim_get_current_buf() == content)
assert(api.nvim_win_get_cursor(middle)[1] == 80)

reader.select("metadata")
reader.mode("panes")

assert(#api.nvim_tabpage_list_wins(0) == 4)

reader.mode("tabs")

assert(#api.nvim_tabpage_list_wins(0) == 3)

vim.cmd.normal("q")

assert(api.nvim_get_current_win() == middle and api.nvim_get_current_buf() == report)
assert(api.nvim_win_get_cursor(middle)[1] == 2 and vim.bo[report].modified)
assert(reader.active() == "reports")
assert(vim.wo[middle].winbar:find("Exported logs", 1, true))
assert(api.nvim_buf_is_valid(content) and api.nvim_buf_is_valid(metadata))

-- Knowledge works in ordinary tabs too, with independent selection and return state.
vim.cmd.tabnew()
local plain = api.nvim_get_current_buf()
knowledge.browse_space(space, "Browse sources", "def", "Extraction details")

assert(#api.nvim_tabpage_list_wins(0) == 1)
assert(reader.active() == "metadata")

reader.select("content")

assert(table.concat(api.nvim_buf_get_lines(0, 0, -1, false), "\n"):find("Other evidence", 1, true))

vim.cmd.normal("q")

assert(api.nvim_get_current_buf() == plain)
assert(vim.wo.winbar == "" and #api.nvim_tabpage_list_wins(0) == 1)

vim.cmd.tabprevious()

assert(reader.active() == "reports" and api.nvim_get_current_buf() == report)

knowledge.browse_space(space, "Browse sources", "abc", "View extracted content")
require("aero.navigation").open_worktree(root)

assert(not vim.t.aero_knowledge_reader)
assert(reader.active() == "reports" and api.nvim_get_current_buf() == report)
assert(api.nvim_win_get_buf(sidebar) == sidebar_buf and api.nvim_win_get_buf(chat) == chat_buf)

vim.fn.delete(root, "rf")
print("knowledge reader: middle-panel tabs, source isolation, view restoration, and workspace return passed")
vim.cmd.qa({ bang = true })
