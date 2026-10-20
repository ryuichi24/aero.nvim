# Worktree change review

Inspect a checkout's final Git changes and draft precise feedback to an agent.

[Back to README](../README.md)

## Open a review

Run `:Aero review`, or press `gr` on a dashboard workspace, worktree, or session.
Aero uses the dashboard selection, focused agent, current tab's agent/worktree,
or working directory. Workspace rows review their main checkout. No agent is
started just to browse changes.

The floating review has a collapsible folder tree on the left and a read-only,
syntax-highlighted diff on the right. Changed files appear beneath their
project-relative folders, with directories first and names sorted alphabetically.
Folders start expanded; their collapse state and the selected entry are retained
when you refresh.

Press `D` in the folder tree to toggle between the diff and the full file with its
language's syntax highlighting. Code view shows the index version for staged
entries, the captured HEAD for branch entries, and disk contents for unstaged and
untracked entries. Deleted files show the pre-deletion version. The mode persists
while browsing and refreshing. Binary files and files larger than 1 MiB have no
code preview. Tree-sitter highlighting is used when a parser is available, with
regular syntax highlighting as a fallback.

Local review labels **staged**, **unstaged**, and **untracked** entries separately.
A file changed both in the index and on disk has two adjacent entries in the same
folder. Renames appear at their destination with their original path shown;
deletions and binary changes remain visible. Staged additions also work before
the repository's first commit.

```text
▾ src/
  ▾ api/
      client.lua [staged] M
      client.lua [unstaged] M
  ▾ ui/
      dialog.lua [untracked] ?
  README.md [unstaged] M
```

These are **worktree changes**, which may include edits by you and several agents.
They are not an attribution of authorship to the selected session.

## Compare a branch against a base

Use an explicit base ref:

```vim
:Aero review main
:Aero review origin/develop
```

Or press `b` in the review to enter a base ref. Aero resolves the base and `HEAD`,
finds their merge-base, and shows **committed changes from that merge-base to the
captured HEAD**. Local staged, unstaged, and untracked changes are excluded from
this comparison. Previews remain tied to the captured commit until refresh.
Missing refs, unrelated histories, or a missing first commit produce an error;
Aero does not silently choose a different base. Press `L` to return to local review.

## Keys

| Key | Action |
| --- | --- |
| `j` / `k` in folder tree | Navigate folders and files; selecting a file loads its diff |
| `<CR>` in folder tree | Toggle a folder, or focus the selected file's diff |
| `h` in folder tree | Collapse an expanded folder, or move to the parent folder |
| `l` in folder tree | Expand a folder, enter its first child, or focus a file's diff |
| `<Tab>` | Switch between folder tree and diff |
| `D` in folder tree | Toggle diff / syntax-highlighted full code |
| `gf` | Open the file in its worktree's code pane; jump to the diff's new-file line when available |
| `a` in diff | Append the cursor's hunk to an agent draft; above the first hunk, quote the full diff |
| Visual `a` | Append exactly the selected diff text to an agent draft |
| Visual `<leader>aq` | Same selection action, using configured `quote_key` |
| `R` in folder tree | Refresh the folder tree and selected diff |
| `b` in folder tree | Choose a branch base ref |
| `L` in folder tree | Return to staged/unstaged/untracked local changes |
| `q` / `<Esc>` | Close the review |

The review requires at least 50 columns and 14 lines. It resizes with Neovim and
closes if the editor becomes too small.

Review controls `b`, `L`, `R`, and `D` are only mapped in the folder tree, leaving
their normal Vim behavior available in the diff/code panel. Press `<Tab>` to
return to the tree to use these controls.

### Custom keymaps

These commands control the currently open review from either pane:

| Command | Action |
| --- | --- |
| `:Aero review diff` | Toggle diff / syntax-highlighted full code |
| `:Aero review refresh` | Refresh changes |
| `:Aero review base` | Choose a branch base ref |
| `:Aero review local` | Return to local changes |

For example, configure your own leader mappings:

```lua
vim.keymap.set("n", "<leader>rd", "<cmd>Aero review diff<CR>", { desc = "Review: toggle diff/code" })
vim.keymap.set("n", "<leader>rr", "<cmd>Aero review refresh<CR>", { desc = "Review: refresh" })
vim.keymap.set("n", "<leader>rb", "<cmd>Aero review base<CR>", { desc = "Review: choose base" })
vim.keymap.set("n", "<leader>rl", "<cmd>Aero review local<CR>", { desc = "Review: local changes" })
```

Open a review with `:Aero review` first. These action names are reserved in the
command; to review a branch named `diff`, for example, use `:Aero review refs/heads/diff`.

## Draft feedback

Open the diff, move to a hunk, and press `a`, or select a range and use Visual `a`.
The feedback includes the worktree, file and old rename path when applicable,
comparison, refresh time, and a fenced diff. A `Feedback:` line is ready for your
comments. Existing draft text is preserved.

In code view, `a` quotes the full file and Visual `a` quotes the selected code,
using a fence labeled with the file's language. `gf` opens the cursor's code line.

Aero prefers the session selected when review opened if it belongs to the reviewed
worktree. Otherwise it uses that worktree's only session, or asks you to choose
between its sessions. With no session, create one before quoting. Feedback is
added to a separate floating feedback composer above the review.
Type `/send` on its own line and press Enter to send and return to the diff,
or normal-mode `q` to keep the draft
and return. Unsent feedback is kept until the review closes. The review stays open so you can quote another hunk while the agent
works; ACP feedback sent while busy follows the normal prompt queue. The regular agent
prompt draft is left untouched. On `/send`, terminal agents receive bracketed paste
followed by Enter. Nothing is submitted automatically when quoting.

Opening a file reuses loaded buffers and preserves their unsaved edits. Deleted
files remain reviewable as diffs; opening a missing file reports that it is missing.
In branch review, `gf` opens the current checkout's file, not a historical blob.

## Refresh and on-disk state

Git reads the index and files **on disk**. Unsaved Neovim buffer contents are not
part of the diff. Save them explicitly if you want them included, then press `R`.
Review itself does not stage, discard, save, commit, or modify files.

The header shows the last refresh time. Writing a file inside the worktree or
regaining application focus marks the review **STALE**; press `R` to reload.
External agent edits are not watched continuously, so refresh before relying on a
diff even if no stale marker appears. Local file listing and preview queries are
separate reads, not an atomic filesystem snapshot; a file can change between them.
Quoted feedback carries a stale label when the view has been marked stale.

Git queries run asynchronously with a ten-second timeout. Individual diff output
is capped at 1 MiB with a visible truncation marker. A file list exceeding 1 MiB
reports an error instead of silently omitting entries. External Git diff programs
and text conversions are disabled for the built-in view.

## Lua API

```lua
require("aero").review()                         -- current selection
require("aero").review("/path/to/worktree")     -- explicit checkout
require("aero").review("/path/to/worktree", "main")
```

The dashboard mapping can be changed or disabled with
`keymaps = { review = "gr" }` or `keymaps = { review = false }`.

## Diff colors

File-list entries have readable status labels: **Added** and **Untracked** in green,
**Modified** and **Renamed** in yellow, and **Deleted** in red. Copied files,
type changes, and conflicts also have explicit labels. Staged/unstaged labels
remain visible separately. File colors use `AeroReviewAdd`, `AeroReviewChange`,
and `AeroReviewDelete` and can be customized like the diff colors below.

Aero highlights added lines in green (`AeroReviewAdd`) and removed lines in red
(`AeroReviewDelete`), independently of the colorscheme's diff syntax colors.
Defaults adapt to light/dark backgrounds when the groups are initialized.
Headers and context lines retain normal diff syntax highlighting.

Override the groups after loading your colorscheme, or from a `ColorScheme` autocmd:

```lua
vim.api.nvim_set_hl(0, "AeroReviewAdd", { fg = "#98c379" })
vim.api.nvim_set_hl(0, "AeroReviewDelete", { fg = "#e06c75" })
```
