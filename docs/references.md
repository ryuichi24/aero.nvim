# Worktree references

Collect reference files and folders for each worktree and attach them to agent drafts.

[Back to README](../README.md)

## Storage and configuration

Use `:Aero reference` for the selected worktree, or the current worktree when editing
code. References live outside the Git checkout by default, under
`stdpath("data")/Aero/workspaces/<workspace>/<worktree>/references`, alongside reports.

```lua
require("aero").setup({
  reference_finder = {
    home = "~/Documents", -- where the finder starts
    directory = "data", -- worktree-scoped storage under stdpath("data")
  },
})
```

`directory` also accepts a path (relative paths resolve inside the worktree), or a
function receiving the worktree path and returning an exact directory path. Use a
distinct path per worktree to retain isolation.

Existing default `context` storage is reused when no `references` directory exists,
preserving files and paths in saved prompts. Custom storage paths remain as configured.
The former `:Aero context`, `:Aero collapse context`, and `/context` commands remain
accepted as legacy aliases; menus and completions use **reference**. Earlier setup
keys `context` and `companion.context` are also accepted; `reference_finder` settings
take precedence when both names are supplied.

## Dashboard

Expanded worktrees show a **References** section with stored files and folders.
Folders end in `/`; `Enter` or `l` expands their children inline, including nested
folders. Use `h` to collapse a folder or move to its parent. Files open in the editor.

Choose **Add +**, or press `a` on a reference row, to open the finder for that
worktree. The list refreshes after transfers. Use `l`/`h`/`Tab` to expand or collapse
the section, or `:Aero collapse reference` to collapse all reference sections.

Press `N` to rename a file or folder, including nested items. Existing names are
never overwritten, and renamed folders retain their expanded state. Dressing/Snacks
input UIs preselect the filename without its final extension; folder names are
selected in full.

Press `d` to delete an item after confirmation. Deleting a folder recursively removes
its stored contents. This removes only the stored reference copy.

## Finder and staging

The finder and staging popup show the target worktree; the finder also shows the
directory being browsed.

| Key | Action |
| --- | --- |
| `Enter` / `l` | Enter a folder |
| `-` / `h` | Go to the parent directory |
| `y` | Mark a file or folder for copying |
| `d` | Mark a file or folder for cutting |
| `u` | Unmark or unstage an item |
| `:w` | Save marked items to the staging popup |
| `q` / `Esc` | Transfer staged items and close |

Copy, cut, and unmark also support visual selections. Hidden files are included,
and marks survive directory navigation. Keep browsing and saving to build the
staging stack. On exit, saved items transfer and unsaved marks are discarded.

Cut sources are removed only when transferred on exit. Existing destination names
and overlapping source selections are rejected rather than overwritten. Transfer
errors keep the finder open so you can resolve them and retry.

## Attach references to prompts

Submit `/reference` in an ACP prompt to select a stored file or folder. Its absolute
path and an instruction to read it are appended to the draft without submitting it.
Choose **Add reference +** to open the finder instead.

In the companion, type `/reference` or choose **Select reference** from Prompt
actions. Selecting an item drafts `/reference select <path>`; add your instructions
below the command and send when ready.

## Companion UI

Open **Workspace → References**, or **Review → References for this worktree** from a
conversation. The companion uses the same storage and `reference_finder.home` as
Neovim. Expand folders inline, preview text/Markdown, and select items to rename
or delete them. Deleting a folder removes its stored contents.

**Add reference** browses files on the **Neovim host**. Mark items with **Copy**/`y`
or **Cut**/`d`, then **Save selections** (or Ctrl/Cmd-S) to stage them.
**Finish finder** transfers saved selections; unsaved selections are discarded.
**Unmark**/`u` and **Unstage** remove selections. **Discard finder** exits without
transferring anything. The target worktree and storage location stay visible.

Reference mutations use the companion's operation receipts and identical-retry flow.
See [companion setup](companion.md) for installation and pairing.

### Source access

Remote filesystem browsing and imports are disabled by default (`roots = {}`).
Paired devices can still browse, attach, rename, and delete stored references.
`reference_finder.home` is a starting directory, not an access boundary.

Enable remote imports from explicit source directories without changing the local finder:

```lua
require("aero").setup({
  reference_finder = { home = "~/Documents" },
  companion = {
    reference_finder = {
      roots = { "~/Documents", "~/Projects/reference" },
      allow_cut = false,
    },
  },
})
```

Allowed roots are checked on the host for browsing, imported files, and recursive
children, including resolved symlink targets. `roots = false` explicitly allows
unrestricted access. `allow_cut = true` (the default) permits cutting within allowed
roots; `false` enforces copy-only imports, including direct API requests.

The finder offers an allowed-root selector. If `reference_finder.home` falls outside
the roots, browsing starts at the first allowed root.

### Transfers and limits

Companion transfers run asynchronously, scan before writing, reserve destinations
exclusively, and copy all items before removing cut sources. Changed sources are
rejected. Failures before cut completion clean up only newly-created copies; if
removal fails after a cut begins, completed copies are retained to avoid data loss.
Conflicting mutations to the same reference directory are rejected during transfers.
Receipt fingerprints bind the action, paths, and transferred items.

Default limits under `companion.reference_finder`:

| Setting | Default |
| --- | --- |
| `max_entries` | 100,000 recursive source entries |
| `max_bytes` | 1 GiB of source file data |
| `max_depth` | 128 nested directory levels |
| `timeout_ms` | 120,000 ms for scanning/copying |
| `max_listing_entries` | 10,000 host finder entries per directory |

Each limit accepts a positive integer, or `false` to disable it. Increase the
relevant limit for larger imports. A timed-out HTTP response does not restart the
transfer: **Retry identical action** retrieves its receipt.

**Cancel reference transfer** requests cancellation during scanning/copying; retry
the original action to collect its final outcome. Cancellation is refused once
verified cut-source removal starts so it cannot interrupt that completion phase.
