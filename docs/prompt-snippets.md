# Prompt snippets

In an ACP prompt buffer, type `/prompt` and press Enter to open the searchable
snippet popup. If command suggestions are visible, Enter first accepts the
command; press Enter again to open the popup. Sending `/prompt` with `Ctrl-s`
or normal-mode Enter also opens it.

Use `j`/`k`, arrow keys, or `Ctrl-n`/`Ctrl-p` to select a snippet. Press `i` to
search by name, description, or prompt content. The preview shows the full prompt;
`Ctrl-d`/`Ctrl-u` scroll it. Enter inserts the selected text into your draft for
editing, without sending it. `q` closes the popup in normal mode and preserves
the draft.

## Create a snippet file

Run `:Aero snippet` to choose **global** or **workspace**, then enter a filename.
Aero creates the folder if necessary, generates a `.jsonc` collection, and opens
it in an editor split. The generated file contains an example prompt, usage notes,
and a commented table of all built-in runtime variables.

The example uses `{{topic}}`, a **custom input variable**, not a built-in.
When you select the snippet, Aero asks for the topic to investigate and replaces
`{{topic}}` with your answer. You can rename it or add placeholders such as
`{{focus}}` to ask your own questions.

You can also choose the scope or supply the filename directly:

```vim
:Aero snippet global
:Aero snippet workspace review
:Aero snippet global testing.jsonc
```

Workspace creation uses the selected/viewed session's workspace, then the current
workspace/worktree or working directory. Linked worktrees use the main repository
root. Global creation uses Neovim's config directory.

Generated files always use `.jsonc` because they include documentation comments.
You can omit the extension; a supplied `.json` extension is changed to `.jsonc`.
Existing `.json` or `.jsonc` collections with the same basename are preserved.
Cancel either question to stop creation. Edit and save the example, then use
`/prompt` to load it; you can add multiple snippets to each file.

## JSON and JSONC files

Manage all snippet files in a `prompt/` folder:

- **Global:** `stdpath("config")/aero/prompt/` (usually `~/.config/nvim/aero/prompt/`).
- **Workspace:** `<workspace-root>/.aero/prompt/`. Linked Git worktrees share the
  main repository's folder. Outside Git, the root is the session's working directory.

```text
~/.config/nvim/aero/prompt/
├── 10-review.jsonc
├── 20-testing.json
└── 30-documentation.jsonc
```

Each file contains the same array of snippets shown below. All immediate `.json`
and `.jsonc` files in the folder are merged into one global collection. Subfolders
and other file extensions are ignored. Files reload whenever the picker opens.

Merge order, from lowest to highest priority:

1. Files in the global `prompt/` folder, sorted alphabetically by filename.
2. Files in the workspace `.aero/prompt/` folder, sorted alphabetically by filename.

Later entries replace earlier snippets with the same case-sensitive name. If a
folder contains both `review.json` and `review.jsonc`, only `review.jsonc` loads.
An invalid file produces a warning while other valid files continue to load.

Workspace snippets support the same folder layout:

```text
<workspace-root>/.aero/prompt/
├── 10-project.jsonc
├── 20-testing.json
└── 30-review.jsonc
```

Workspace files override global snippets and earlier workspace snippets by name.
The same JSONC preference, comment support, error handling, and reload rules apply
to both folders. An invalid JSONC file produces a warning rather than falling
back to a matching JSON file.

Both extensions accept `//` line comments, `/* ... */` block comments, and trailing
commas. Comment markers inside quoted strings remain literal, so URLs and prompt
text are preserved. For example, `prompt/review.jsonc` can contain:

```jsonc
[
  // Shared review template
  {
    "name": "Review",
    "prompt": "Review {{branch}} for correctness.", // Runtime variable
  },
]
```

Each file contains an array of snippets:

```json
[
  {
    "name": "Code review",
    "description": "Review changes for correctness and missing tests",
    "prompt": "Review the current changes.\nFocus on correctness, edge cases, and missing tests."
  },
  {
    "name": "Explain",
    "prompt": "Explain how this code works, with concrete examples."
  }
]
```

`name` and `prompt` are required non-empty strings; `description` is optional.
Prompt text preserves newlines and supports runtime variables (see below). Names must be unique
within each file. Workspace snippets override global snippets with the same
case-sensitive name. The popup labels each snippet's scope.

Files are reloaded whenever the picker opens. Missing folders are fine; invalid
files produce a warning while snippets from other valid files remain usable.
Selecting a snippet replaces a draft containing only `/prompt`; when opened
programmatically with `require("aero.prompt_snippets").open(chat)`, it appends
to an existing draft with a blank line between them.

## Runtime variables

Use `{{variable}}` in prompt text. Whitespace inside the braces is optional,
and variable names are case-sensitive identifiers (letters, digits, underscores;
starting with a letter or underscore).

| Variable | Value |
| --- | --- |
| `{{workspace}}` | Main repository root, or session working directory outside Git |
| `{{worktree}}` | Session's worktree path |
| `{{session}}` | Session name |
| `{{cwd}}` | Neovim's current working directory when the picker opens |
| `{{date}}` | Local date, `YYYY-MM-DD` |
| `{{time}}` | Local time, `HH:MM:SS` |
| `{{workspace_name}}` | Workspace root folder name |
| `{{worktree_name}}` | Session worktree folder name |
| `{{branch}}` | Session worktree's current Git branch (empty for detached HEAD) |
| `{{file}}` | Absolute path of the source editor's file |
| `{{filetype}}` | Source buffer's Neovim filetype, e.g. `lua` |
| `{{selection}}` | Last visual selection in the source buffer |
| `{{diagnostics}}` | Source buffer diagnostics, including path, line, column, severity, and message |
| `{{diff}}` | Tracked staged and unstaged changes relative to `HEAD` in the session worktree |

Built-in values are captured when the picker opens and appear in the preview.
Editor values use Aero's remembered source window in the current tab, rather than
the composer or picker. Selection uses the source buffer's last visual marks
(character, line, or block selection). Missing source context, unavailable Git
values, or a missing selection expand to empty strings. Git commands have a
two-second timeout; diff excludes untracked files and is empty before the first
commit. Git branch and diff are only queried when a loaded template uses them.
Any other variable asks for input when you select the snippet. Repeated uses
of the same variable ask only once, in first-appearance order. Empty input is
allowed; cancelling any input leaves the draft untouched. Entered values are
inserted literally, without expanding any placeholders they contain.

```json
[
  {
    "name": "Investigate",
    "description": "Investigate a topic in this workspace",
    "prompt": "In {{workspace}}, investigate {{topic}}.\nFocus on {{focus}}.\nSummarize findings about {{topic}} as of {{date}}."
  }
]
```

This example asks for `topic` and `focus`, then inserts the completed prompt
into the draft for review before sending.
