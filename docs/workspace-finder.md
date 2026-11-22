# Add a workspace

The dashboard's Add workspace action opens a folder explorer using the same
navigation as the reference finder. It starts in your home directory. Configure
another starting directory with:

```lua
require("aero").setup({
  workspace_finder = { home = "~/dev" },
})
```

Git repository folders (including linked worktrees) use `AeroWorkspaceGitFolder`,
linked to `Special` by default, to distinguish them from navigation folders.
Customize the color after loading your colorscheme:

```lua
vim.api.nvim_set_hl(0, "AeroWorkspaceGitFolder", { fg = "#98c379", bold = true })
```

| Key | Action |
| --- | --- |
| Enter / `l` | Enter the selected folder |
| `-` / `h` | Go to the parent folder |
| `y` | Stage selected folders (also supports visual selections) |
| `u` | Unstage selected folders |
| `:w` | Apply edited folder names on disk |
| `q` / Escape | Add all staged Git repositories as workspaces and close |
| `n` | Create a new folder and initialize Git inside it |

Creating a Git folder enters it; go to its parent and yank it to stage it. Folder names
must be a single new directory name. Existing folders are never reinitialized.
You can still pass a repository path directly to `require("aero").add_workspace(path)`.

Edit a folder's name directly in its existing line, keeping the two leading spaces
and trailing `/`, then run `:w`. Staged paths follow renamed folders. Save name
changes before navigating, staging, or finishing. Renames cannot overwrite existing
folders or add/remove listing lines.
