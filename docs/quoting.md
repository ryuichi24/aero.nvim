# Quoting code and agent logs

Add selected text to an agent's next prompt with its source and line range.

[Back to README](../README.md)

Select with `v`, `V`, or `<C-v>` and press `<leader>aq`. With the default leader,
press `\`, then `a`, then `q`. In terminal scrollback, first use `<C-\><C-n>`.

Quotes preserve selected text in a fenced block. Code paths inside the target worktree
are relative to that checkout. Characterwise, linewise, blockwise, and exclusive Visual
selections are supported without changing the source buffer or yank registers.

## Targeting

- **Code:** targets the panel session, or its last session when hidden. Otherwise uses
  the current worktree's session, asking you to choose if several are available.
- **Agent logs:** targets that log's own session even if another is in the panel.
- **ACP:** appends to the existing draft and focuses it without submitting.
- **Terminal:** bracketed-pastes into CLI input without a submit keystroke.

Add a question or edit the quote before sending it.

## Configuration and API

The mapping is installed by `setup()` or first opening Aero.

```lua
require("aero").setup({ quote_key = "<leader>aq" }) -- false disables it
```

`require("aero").quote()` uses the active Visual selection. `:'<,'>Aero quote` or
`:10,15Aero quote` quotes complete lines; use the visual mapping for partial-line
and block selections.
