# Agent reading lists

Ask an ACP agent to prepare an ordered walkthrough from an entry point to its
outcome, or publish a checklist of findings. Each stop includes a source location,
short label, and optional explanation. Lists are saved per worktree under
`stdpath("data")/Aero/reading`, independently of quickfix history.

## Setup

Enable the reading tool before starting or restarting an ACP session:

```lua
require("aero").setup({
  reading = { agent = { enabled = true } },
})
```

The tool uses the same `aero-mcp` executable as task integration. Install a matching
release with `:Aero tasks install`. For a development checkout, run
`make build-mcp` and set `reading.agent.executable` to the absolute path of
`apps/mcp/aero-mcp`. Task-agent integration does not need to be enabled.
Requires macOS/Linux and an ACP adapter that supports stdio MCP servers.

Example prompt:

Type `/reading` on its own line in an ACP prompt and press Enter. Aero asks for a
list title and replaces the command with an editable walkthrough request. You can
also type `/reading Authentication flow` to provide the title directly. Existing
draft text is preserved; send the completed draft with Ctrl-Enter.

Customize the generated request with `reading.prompt`. `{title}` is replaced with
the JSON-quoted title (including surrounding quotes); multiline templates are supported:

```lua
require("aero").setup({
  reading = {
    prompt = [[Create a new reading list titled {title} using aero_reading_list_publish.
Trace from the entry point to the outcome. Explain each stop and include error branches.]],
  },
})
```

Or write the request yourself:

> Trace prompt submission from the key mapping through the ACP request and response.
> Use aero_reading_list_publish to prepare a curated reading list in execution order.
> Include an explanation of each stop and its connection to the next one.

## Create and edit lists manually

No agent connection or MCP executable is needed for manual lists:

1. Run `:Aero reading new`, enter a title, and create an empty list. Aero opens its
   editable JSON document in a split.
2. Return to a saved source file, place the cursor at a useful location, and run
   `:Aero reading add`. Choose a list and enter a label. Repeat to collect stops.
3. Run `:Aero reading edit` to choose a list and edit its title or entries. Save
   with `:w`. Change labels and notes, reorder the item objects, or remove items.
4. Run `:Aero reading` to navigate and track progress in quickfix.

The editor accepts items such as:

```json
{
  "title": "Authentication flow",
  "items": [
    { "path": "src/auth.lua", "lnum": 12, "label": "Entry point", "note": "Follow token validation from here." }
  ]
}
```

New entries may omit `id`; saving generates it. Preserve existing IDs when
reordering or editing to retain read progress. Optional `end_lnum` marks the end
of a source range. File and line validation is the same as for agent-created lists.
Empty lists are allowed. Manual editing also works on agent-created lists and
retains their session ownership; agents cannot overwrite manually created lists.

Unsaved edits stay in the editor buffer. If another action changes the list's
contents after the editor opens, saving reports a conflict; discard that editor
with `:bwipeout!` and reopen it to load the latest version. Progress-only changes
do not conflict and are preserved on save.

## Navigation and progress

Each expanded worktree in the Aero sidebar includes a **Reading lists** section.
Lists show their title and read progress. Use Enter or `l` on a list to open its
quickfix entries in that worktree, or on **New reading list +** to create a manual list there.
Use `h`/`l` to collapse or expand the section; `h` on a list returns to its section.
The sidebar updates automatically when lists are published, edited, or marked read.
`:Aero collapse reading` collapses all reading-list sections.

- `:Aero reading`: choose a saved list in the current worktree and open quickfix.
- Enter opens the selected stop in the reader panel's **Reading** tab, preserving
  the **Source** tab and agent panel. `:Aero reading next` uses the same tab.
- `:cnext` and `:cprevious`: standard quickfix navigation.
- `:Aero reading source`: open the current quickfix stop in **Source**, keeping
  the **Reading** slot intact. Lua: `require("aero").reading("source")`.
- `x` in the reading quickfix window, or `:Aero reading toggle`: mark/unmark a stop.
- `K` in the reading quickfix window, or `:Aero reading note`: show its explanation.
- `:Aero reading next`: jump to the next unread stop, wrapping at the end.

Jumping does not mark a stop read. Progress survives restarts and agent updates.
Opening a list creates a new quickfix list; previous searches remain in quickfix
history (`:colder`). Publishing refreshes already-open projections without opening
a window or moving focus. The stored walkthrough remains available after quickfix
history is discarded. Source line numbers are snapshots and can become stale after edits.

## Publication API

`aero_reading_list_publish` accepts `title` and an ordered `items` array (1–500
entries). Each item needs a unique stable `id`, worktree-relative `path`, one-based
`lnum`, and single-line `label`; `end_lnum` and `note` are optional. Files must exist
inside the session worktree. Repeated source locations with different IDs are allowed.

Omit the list `id` to create a list. Reuse the returned `id` to replace its contents;
read states are preserved for retained item IDs. A session can only update its own
lists. Agents cannot mark items read. The Lua equivalent is
`require("aero.reading").publish({ worktree = path, session_key = key }, args)`.
