-- Shell hooks record submitted commands, rather than guessing from terminal output.
local M = {}
local sessions = {}
local storage = require("aero.storage")

function M.directory(worktree)
	worktree = storage.canonical(worktree)
	local root = storage.canonical(require("aero.git").main_root(worktree) or worktree)
	return vim.fs.joinpath(
		vim.fn.stdpath("data"),
		"Aero",
		"workspaces",
		storage.folder(root),
		storage.folder(worktree),
		"terminal-history"
	)
end

local function history_file(worktree)
	return vim.fs.joinpath(M.directory(worktree), "commands.jsonl")
end

-- Portable shell JSON encoding avoids adding a runtime dependency on Python or jq.
local hooks = [=[
_aero_history_json() {
  local value="$1" char number
  printf '"'
  while [ -n "$value" ]; do
    char=${value%"${value#?}"}; value=${value#?}
    case "$char" in
      '"') printf '%s' '\"' ;;
      '\') printf '%s' '\\' ;;
      *)
        printf -v number '%d' "'$char"
        if [ "$number" -ge 0 ] && [ "$number" -lt 32 ]; then printf '\\u%04x' "$number"; else printf '%s' "$char"; fi ;;
    esac
  done
  printf '"'
}
_aero_history_clock() {
  local now=${EPOCHREALTIME:-$(date +%s)} fraction
  fraction=${now#*.}
  [ "$fraction" = "$now" ] && fraction=0
  fraction=${fraction}000000
  fraction=${fraction%"${fraction#??????}"}
  _aero_history_us=${now%%.*}${fraction}
}
_aero_history_write() {
  local code="$1" duration="$2" line
  printf -v line '{"id":%s,"command":%s,"cwd":%s,"started_at":%s,"exit_code":%s,"duration_seconds":%s}' \
    "$(_aero_history_json "$_aero_history_id")" "$(_aero_history_json "$_aero_history_command")" \
    "$(_aero_history_json "$_aero_history_cwd")" "$_aero_history_started" "$code" "$duration"
  printf '%s\n' "$line" >> __FILE__
}
_aero_history_start() {
  _aero_history_command="$1"
  _aero_history_cwd=$PWD
  _aero_history_clock
  _aero_history_start_us=$_aero_history_us
  printf -v _aero_history_started '%d.%06d' "$((_aero_history_us / 1000000))" "$((_aero_history_us % 1000000))"
  _aero_history_id="$$-$_aero_history_us-${_aero_history_count:=0}"
  _aero_history_count=$((_aero_history_count + 1))
  _aero_history_active=1
  _aero_history_write null null
}
_aero_history_finish() {
  local result=$? elapsed duration
  if [ -n "$_aero_history_active" ]; then
    _aero_history_active=
    _aero_history_clock
    elapsed=$((_aero_history_us - _aero_history_start_us))
    [ "$elapsed" -lt 0 ] && elapsed=0
    printf -v duration '%d.%06d' "$((elapsed / 1000000))" "$((elapsed % 1000000))"
    _aero_history_write "$result" "$duration"
  fi
  return "$result"
}
]=]

function M.prepare(worktree, cmd)
	if type(cmd) ~= "table" or #cmd ~= 1 then
		return cmd
	end

	local shell = vim.fn.fnamemodify(cmd[1], ":t")

	if shell ~= "bash" and shell ~= "zsh" then
		return cmd
	end

	local dir = vim.fn.tempname()
	vim.fn.mkdir(dir, "p", 448)
	vim.fn.mkdir(M.directory(worktree), "p", 448)
	local file = history_file(worktree)
	local fd, err = vim.uv.fs_open(file, "a", 384)
	assert(fd, err)
	vim.uv.fs_close(fd)
	local quoted = vim.fn.shellescape(file)
	local common = vim.split((hooks:gsub("__FILE__", function()
		return quoted
	end)), "\n")
	local result, env

	if shell == "bash" then
		local lines = {
			"[[ -f ~/.bashrc ]] && source ~/.bashrc",
			-- Keep duplicates and leading-space commands in this shell's history.
			"HISTCONTROL=; HISTIGNORE=",
			"_aero_history_last=$(HISTTIMEFORMAT= builtin history 1)",
			"_aero_history_ready=",
		}
		vim.list_extend(lines, common)
		vim.list_extend(lines, {
			"_aero_history_begin() {",
			"  local result=$? line=$(HISTTIMEFORMAT= builtin history 1)",
			'  if [[ -n $_aero_history_ready && $line != "$_aero_history_last" ]]; then',
			"    _aero_history_last=$line",
			"    if [[ $line =~ ^[[:blank:]]*[0-9]+[[:blank:]]{2}(.*)$ ]]; then",
			'      _aero_history_start "${BASH_REMATCH[1]}"',
			"    fi",
			"  fi",
			'  return "$result"',
			"}",
			"_aero_history_prompt() {",
			"  _aero_history_finish",
			"  local result=$?",
			"  _aero_history_last=$(HISTTIMEFORMAT= builtin history 1)",
			"  _aero_history_ready=1",
			'  return "$result"',
			"}",
			"if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1) )); then",
			'  PROMPT_COMMAND=( _aero_history_prompt "${PROMPT_COMMAND[@]}" )',
			"else",
			'  PROMPT_COMMAND="_aero_history_prompt; $PROMPT_COMMAND"',
			"fi",
			"_aero_history_debug_trap=$(trap -p DEBUG)",
			"if [[ -n $_aero_history_debug_trap ]]; then",
			"  _aero_history_debug_trap=${_aero_history_debug_trap#trap -- }",
			"  _aero_history_debug_trap=${_aero_history_debug_trap% DEBUG}",
			'eval "_aero_history_previous_debug=$_aero_history_debug_trap"',
			"fi",
			[[trap '_aero_history_begin; eval "$_aero_history_previous_debug"' DEBUG]],
			"_aero_history_exit_trap=$(trap -p EXIT)",
			"if [[ -n $_aero_history_exit_trap ]]; then",
			"  _aero_history_exit_trap=${_aero_history_exit_trap#trap -- }",
			"  _aero_history_exit_trap=${_aero_history_exit_trap% EXIT}",
			'eval "_aero_history_previous_exit=$_aero_history_exit_trap"',
			"fi",
			[[trap '_aero_history_finish; eval "$_aero_history_previous_exit"' EXIT]],
		})
		vim.fn.writefile(lines, dir .. "/bashrc")
		result = { cmd[1], "--rcfile", dir .. "/bashrc", "-i" }
	else
		local original = vim.env.ZDOTDIR or vim.env.HOME

		-- Restore ZDOTDIR before user configuration, so plugins see the real directory.
		vim.fn.writefile({
			"export ZDOTDIR=" .. vim.fn.shellescape(original),
			'[[ -f "$ZDOTDIR/.zshenv" ]] && source "$ZDOTDIR/.zshenv"',
			"_aero_history_zdotdir=$ZDOTDIR",
			"ZDOTDIR=" .. vim.fn.shellescape(dir),
		}, dir .. "/.zshenv")
		local lines = {
			"ZDOTDIR=$_aero_history_zdotdir",
			'[[ -f "$ZDOTDIR/.zshrc" ]] && source "$ZDOTDIR/.zshrc"',
			"zmodload zsh/datetime",
		}
		vim.list_extend(lines, common)
		vim.list_extend(lines, {
			"autoload -Uz add-zsh-hook",
			"add-zsh-hook preexec _aero_history_start",
			"add-zsh-hook zshexit _aero_history_finish",
			"if (( $+functions[precmd] )); then",
			"  functions[_aero_history_user_precmd]=$functions[precmd]",
			'  precmd() { _aero_history_finish; _aero_history_user_precmd "$@"; }',
			"else",
			"  precmd() { _aero_history_finish; }",
			"fi",
		})
		vim.fn.writefile(lines, dir .. "/.zshrc")
		result, env = { cmd[1], "-i" }, { ZDOTDIR = dir }
	end

	local old = sessions[worktree]
	sessions[worktree] = { dir = dir }

	if old then
		vim.fn.delete(old.dir, "rf")
	end

	return result, env
end

function M.list(worktree)
	local commands, ids = {}, {}

	-- Legacy entries have no execution metadata. Keep their original file intact.
	local legacy = io.open(vim.fs.joinpath(M.directory(worktree), "commands"), "rb")

	if legacy then
		local data = legacy:read("*a")
		legacy:close()

		for command in data:gmatch("([^%z]*)%z") do
			command = command:gsub("^\t ?", "")

			if vim.trim(command) ~= "" then
				commands[#commands + 1] = { command = command }
			end
		end
	end

	local file = io.open(history_file(worktree), "rb")

	if file then
		for line in file:lines() do
			local ok, entry = pcall(vim.json.decode, line)

			if ok and type(entry) == "table" and type(entry.command) == "string" then
				for _, field in ipairs({ "cwd", "started_at", "exit_code", "duration_seconds" }) do
					if entry[field] == vim.NIL then
						entry[field] = nil
					end
				end

				local index = type(entry.id) == "string" and ids[entry.id]

				if index then
					commands[index] = entry
				else
					commands[#commands + 1] = entry

					if type(entry.id) == "string" then
						ids[entry.id] = #commands
					end
				end
			end
		end

		file:close()
	end

	return commands
end

local function cleanup(worktree)
	local session = sessions[worktree]

	if session then
		vim.fn.delete(session.dir, "rf")
	end

	sessions[worktree] = nil
end

--- Forget shell integration files while keeping saved commands, like reports and exports.
function M.delete(worktree)
	cleanup(worktree)
end

vim.api.nvim_create_autocmd("VimLeavePre", {
	callback = function()
		for worktree in pairs(sessions) do
			cleanup(worktree)
		end
	end,
})
return M
