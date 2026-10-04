# Markdown reports

Create worktree-specific documents and attach them to agent drafts for review or updates.

[Back to README](../README.md)

## Attach or create a report

Run `:Aero report` from a log/prompt, worktree/session dashboard row, or code pane.
A floating menu lists reports followed by **New +**. Use `j/k` or arrows, `<CR>` to
select, and `<Esc>`/`q` to cancel. Aero asks for a recipient when several agents are
available without a selected session.

In ACP prompts, typing `/report` and pressing Enter opens the picker. Sending it with
`:w` or `<C-s>` also works; `<C-x><C-o>` completes it. Enter in other insert-mode
drafts continues to insert a newline.

Selecting appends the absolute path and an instruction to read/update the report to
the existing draft. **New +** asks for a filename, adds `.md` if needed, and creates
an empty file without overwriting an existing one. Nothing is submitted automatically;
add your task before sending. Terminal agents receive bracketed paste.

## Dashboard actions

Reports appear in an expandable section beneath each worktree. `<CR>` opens a report
in code; `<C-v>` / `<C-x>` / `<C-t>` open a split/tab. **New +** or `a` in this section
creates and opens a report. `N` renames it; `d` confirms deletion of its file.
Session deletion is independent. `R` refreshes after external changes; Markdown writes
and agent activity also refresh the list.

## Storage

Default path:

```text
stdpath("data")/Aero/workspaces/<workspace>/<worktree>/reports/*.md
```

Folder names combine directory basenames and short path hashes to avoid collisions.
Reports are discovered from disk and survive restarts.

| `reports.directory` | Location |
| --- | --- |
| `"data"` | Default hierarchy above |
| `"worktree"` | `<target-worktree>/.aero/reports` |
| Absolute root | `<root>/<workspace>/<worktree>/reports` |
| Relative path | Exact directory inside each target worktree |
| Function `(worktree, workspace_root)` | Exact returned directory; relative results resolve inside the worktree |

```lua
require("aero").setup({ reports = { directory = ".notes/reports" } })
```

## Custom attachment text

Every `{path}` in `reports.prompt` becomes the JSON-quoted absolute path; other text
is literal. This applies to ACP and terminal agents.

```lua
require("aero").setup({
  reports = {
    prompt = "Report file: {path}\nRead the report and update it with a concise summary of your findings.",
  },
})

vim.keymap.set("n", "<leader>ar", "<cmd>Aero report<cr>")
vim.keymap.set("i", "<leader>ar", "<cmd>Aero report<cr>")
```
