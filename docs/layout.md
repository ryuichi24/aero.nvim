# Panels, resizing, and fullscreen

Arrange code, agents, prompts, and shells while keeping their buffers and processes alive.

[Back to README](../README.md)

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
