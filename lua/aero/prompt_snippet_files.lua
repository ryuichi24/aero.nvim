-- Create editable JSONC collections with an embedded quick-start reference.
local M = {}

function M.starter(name)
	local header = [[// Aero prompt snippets
// Add objects to this array; each needs a unique name and a non-empty prompt.
// prompt accepts a string or an array of strings: one item per line, "" for a blank line.
// description is optional. You can also use \n inside a prompt string for a newline.
// Comments and trailing commas are supported. Save, then open /prompt to reload.
// Files load alphabetically; later names win. Workspace snippets override global ones.
// {{custom_name}} asks for input; repeated variables ask once. Cancel keeps the draft.
// The example's {{topic}} is a custom input variable, not a built-in:
// selecting this snippet asks what topic to investigate and inserts your answer.
// Replace it or add placeholders such as {{focus}} to ask your own questions.
// Built-ins are captured when /prompt opens; unavailable context becomes empty text.
// Editor context comes from the source window, not the composer.
//
// | Variable           | Runtime value                                      |
// | ------------------ | -------------------------------------------------- |
// | {{workspace}}      | Main repository root (session directory outside Git) |
// | {{worktree}}       | Session worktree path                              |
// | {{session}}        | Session name                                       |
// | {{cwd}}            | Neovim current working directory                   |
// | {{date}}           | Local date: YYYY-MM-DD                             |
// | {{time}}           | Local time: HH:MM:SS                               |
// | {{workspace_name}} | Workspace root folder name                         |
// | {{worktree_name}}  | Session worktree folder name                       |
// | {{branch}}         | Git branch (empty for detached HEAD)               |
// | {{file}}           | Absolute source-file path                          |
// | {{filetype}}       | Source buffer filetype, e.g. lua                    |
// | {{selection}}      | Last visual selection in the source buffer         |
// | {{diagnostics}}    | Source diagnostics: path, position, severity, message |
// | {{diff}}           | Tracked staged + unstaged changes against HEAD     |
//
// Diff excludes untracked files and is empty before the first commit.
// Variable names are case-sensitive: letters/digits/underscores, no leading digit.
// Values are inserted literally and the generated prompt is not sent automatically.
]]
	return header .. "[\n  {\n    \"name\": " .. vim.json.encode(name)
		.. ',\n    "description": "Investigate a topic in this workspace",\n'
		.. '    "prompt": [\n'
		.. '      "In {{workspace_name}}, investigate {{topic}}.",\n'
		.. '      "",\n'
		.. '      "Focus on correctness and explain your findings as of {{date}}."\n'
		.. '    ]\n'
		.. "  }\n]\n"
end

function M.directory(scope, worktree)
	if scope == "global" then return vim.fs.joinpath(vim.fn.stdpath("config"), "aero", "prompt") end
	if scope ~= "workspace" then return nil, "scope must be global or workspace" end
	local root = require("aero.git").main_root(worktree) or worktree
	return vim.fs.joinpath(root, ".aero", "prompt")
end

function M.create(scope, worktree, name)
	if type(name) ~= "string" or vim.trim(name) == "" then return nil, "a filename is required" end
	name = vim.trim(name)
	if name:find("[/\\%c]") or name == "." or name == ".." then
		return nil, "use a filename without directory separators or control characters"
	end
	-- Generated files include comments, so always use the JSONC extension.
	name = name:gsub("%.jsonc?$", "")
	if name == "" or name == "." or name == ".." then return nil, "a filename is required" end
	local directory, err = M.directory(scope, worktree)
	if not directory then return nil, err end
	local ok, mkdir_err = pcall(vim.fn.mkdir, directory, "p")
	if not ok then return nil, tostring(mkdir_err) end
	local path = vim.fs.joinpath(directory, name .. ".jsonc")
	-- Do not silently shadow an existing JSON collection with a JSONC counterpart.
	if vim.uv.fs_stat(vim.fs.joinpath(directory, name .. ".json")) then
		return nil, "a JSON collection with that name already exists"
	end
	local fd, open_err = vim.uv.fs_open(path, "wx", 420)
	if not fd then return nil, "could not create snippet file: " .. tostring(open_err) end
	local text = M.starter(name)
	local written, write_err = vim.uv.fs_write(fd, text, 0)
	local closed, close_err = vim.uv.fs_close(fd)
	if written ~= #text or not closed then
		vim.uv.fs_unlink(path)
		return nil, "could not write snippet file: " .. tostring(write_err or close_err or "incomplete write")
	end
	return path
end

function M.new(scope, name)
	if scope and scope ~= "global" and scope ~= "workspace" then
		vim.notify("Aero: use :Aero snippet [global|workspace] [filename]", vim.log.levels.WARN)
		return
	end
	local selected = require("aero.session_target").resolve("viewed")
	local worktree = selected and selected.worktree or vim.b.aero_workspace_root or vim.t.aero_worktree or vim.fn.getcwd()
	local function choose_name(chosen_scope)
		if not chosen_scope then return end
		local function create(filename)
			if filename == nil then return end
			local path, err = M.create(chosen_scope, worktree, filename)
			if not path then
				vim.notify("Aero: " .. err, vim.log.levels.WARN)
				return
			end
			local win = require("aero.navigation").code_window()
			if win and vim.api.nvim_win_is_valid(win) then vim.api.nvim_set_current_win(win) end
			vim.cmd("split " .. vim.fn.fnameescape(path))
			vim.bo.filetype = "jsonc"
		end
		if name then return create(name) end
		vim.ui.input({ prompt = "New " .. chosen_scope .. " prompt file: ", default = "my-prompts.jsonc" }, create)
	end
	if scope then return choose_name(scope) end
	vim.ui.select({ "global", "workspace" }, { prompt = "New prompt snippet collection" }, choose_name)
end

return M
