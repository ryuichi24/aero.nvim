# Panels, resizing, and fullscreen

Arrange code, agents, prompts, and shells while keeping their buffers and processes alive.

[Back to README](../README.md)

## Reader panel

Within each worktree, the reader panel has independent **Source**, **Exported logs**,
**References**, and **Reports** reading slots. Opening a report, exported log, or
reference from the dashboard selects its slot without replacing the source buffer.
Each slot keeps its buffer and reading position when switching. Returning to a
worktree through search restores its last selected reading slot, including its
buffer and reading position, within the current Neovim session.

### Opening source files

Select a worktree in the sidebar and press `e` to open its root directory in the
**Source** slot. Aero uses Oil when installed, or Neovim's directory browser
otherwise. Select a file there to read or edit it. Pressing `e` on a report or
exported log still opens that document in its own slot.

Use Ctrl-Enter or Ctrl-click on a worktree to resume its last selected reading slot
instead of reopening the root directory. To return to the current source reader, click
**Source** or run `:Aero reader source`.

### Switching reading slots

Click a slot in the reader panel's window bar, or use:

| Command | Reading slot |
| --- | --- |
| `:Aero reader source` | Source |
| `:Aero reader exports` | Exported logs |
| `:Aero reader references` | References |
| `:Aero reader reports` | Reports |

These slots are local to the reader panel; they do not create Neovim tabpages.
`gt` and `gT` switch Neovim tabpages rather than reading slots.

For custom keymaps, call the public Lua function directly:

```lua
local aero = require("aero")

vim.keymap.set("n", "<leader>rs", function()
	aero.reader("source")
end, { desc = "Reader: Source" })

vim.keymap.set("n", "<leader>re", function()
	aero.reader("exports")
end, { desc = "Reader: Exported logs" })

vim.keymap.set("n", "<leader>rf", function()
	aero.reader("references")
end, { desc = "Reader: References" })

vim.keymap.set("n", "<leader>rr", function()
	aero.reader("reports")
end, { desc = "Reader: Reports" })

vim.keymap.set("n", "<leader>rm", function()
	aero.reader()
end, { desc = "Reader: Toggle tabs/panes" })

vim.keymap.set("n", "<leader>rt", function()
	aero.reader("tabs")
end, { desc = "Reader: Tabs mode" })

vim.keymap.set("n", "<leader>rp", function()
	aero.reader("panes")
end, { desc = "Reader: Panes mode" })
```

### Tabs and panes modes

Click the `tabs ⇄` / `panes ⇄` control, or run `:Aero reader` to toggle the display.
`:Aero reader panes` shows opened slots in stacked reader-panel splits;
`:Aero reader tabs` returns to one reading window. Buffers, including unsaved edits,
are retained in either mode.

Use `<C-w>w` or `<C-w>p` to navigate between panes. Aero's default resize mappings
use `<C-w>j` and `<C-w>k` for resizing; disabling those mappings restores native
directional window navigation. See [Resizing](#resizing).

## Agent panel

Sessions open in a fixed-width panel beside code. Files edited by agents update in
open buffers. The title bar identifies the session, worktree, and current activity.
ACP activity includes thinking, writing, tool titles, permission waits, and elapsed time.
Terminal sessions spin while producing output; `animation = false` uses static icons.

| Command | Action |
| --- | --- |
| `:Aero panel` | Toggle the panel, remembering the last session per tab |
| `:Aero prompt` | Focus input, opening the panel if needed |
| `:Aero fullscreen` | Toggle fullscreen for the focused pane |

Code opens never land in the panel. Dashboard `<C-v>` / `<C-x>` / `<C-t>` can still
open sessions in separate splits/tabs. Set `panel = false` to use the last-used window.
When a terminal agent exits, its panel returns to normal mode and retains scrollback;
use `<C-w>w` to leave without a terminal escape.

## Resizing

Enable `:set mouse=a` to drag window borders. In normal mode:

| Key / command | Action |
| --- | --- |
| `<C-w>+` / `<C-w>-` | Increase / decrease height |
| `<C-w>j` / `<C-w>k` | Shrink / grow by one line |
| `<C-w>h` / `<C-w>l` | Narrow / widen by one column |
| `<C-w>>` / `<C-w><` | Increase / decrease width |
| `:resize 12` | Set height to 12 lines |
| `:vertical resize 80` | Set width to 80 columns |

Leave insert mode with `<Esc>`; enter terminal normal mode with `<C-\><C-n>`.
Counts work with native resize commands, such as `5<C-w>+`.

After starting a directional resize, repeat `h/j/k/l` without the prefix:
`<C-w>kkk` grows three lines. Any other key or leaving the pane ends resize mode.
These mappings replace directional window navigation in Aero panes, including code
in Aero tabs; use `<C-w>w` or `<C-w>p` for navigation. Other code tabs keep native behavior.

```lua
require("aero").setup({
  resize = {
    prefix = "<C-w>",
    keys = { grow = "k", shrink = "j", narrow = "h", widen = "l" },
  }, -- false disables these mappings everywhere
})
```

The legacy `resize_keys` table of full shortcuts is supported; `acp.resize_keys`
can override full shortcuts specifically for prompts.

Dashboard/panel widths are remembered per tab, prompt height per session/tab, and
shell height per worktree/tab for the current Neovim instance. Sizes survive hiding,
reopening, and sending prompts. Initial defaults are dashboard **40 columns**, panel
**80 columns**, prompt **25 lines**, and shell **12 lines**. Once resized, remembered
sizes take precedence until Neovim exits.

Aero automatically rebalances side columns when panes open/close or the editor changes
size. Reopening the middle code pane (including raw board Markdown) clears inherited
fixed-width options and reserves at least **20 columns** where screen space permits.
Dashboard and agent widths shrink proportionally when necessary; their preferred sizes
are retained and restored on a larger screen. Closing the editor does not remember the
neighbors' expanded widths as new preferences. Code buffers, drafts, and focus are kept.
Dedicated Kanban tabs use their own column layout, and fullscreen panes are excluded.

```lua
require("aero").setup({
  layout = { min_code_width = 40 }, -- default 20; layout = false disables rebalancing
})
```

```lua
require("aero").setup({
  acp = { prompt_height = 12 },
  panel = { width = 80 },
})
```

## Fullscreen

Press `gF` in normal mode or run `:Aero fullscreen` from code, dashboard, agent
transcript/prompt, or shell. Aero opens a temporary tab using the same buffers/session.
Toggle again, or close the temporary tab, to restore the original layout and focus.

ACP fullscreen retains the prompt beneath the transcript; `i` or `:Aero prompt` opens
it when needed. Drafts are kept. Fullscreen starts with the current prompt height,
but resizing there does not change the original tab's layout.

Set `fullscreen_key = false` to disable `gF`, or choose another key. For other modes:

```lua
vim.keymap.set("n", "<leader>af", "<cmd>Aero fullscreen<cr>")
vim.keymap.set("i", "<C-g>", "<Esc><cmd>Aero fullscreen<cr>")
vim.keymap.set("t", "<C-g>", "<C-\\><C-n><cmd>Aero fullscreen<cr>")
```
