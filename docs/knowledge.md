# Knowledge base

Knowledge base is a local research environment alongside Workspace
and General. Collections group spaces; spaces own sources, notes, and
multiple independent agent sessions.

## Start in Neovim

For a development checkout, run `make build-all` so both native helpers include
the knowledge protocol. Knowledge sessions prefer the local MCP build unless an
executable is configured; `knowledge.executable` can select an explicit updated
helper. An older installed helper is rejected with a rebuild instruction.

1. Restart Neovim after updating the plugin and run `:Aero open`.
2. Expand **Knowledge base** and choose **Manage knowledge +**.
3. Create a collection, then a space. Enter on a collection opens its management
   picker; Enter on a space opens its sources, sessions, and notes.
4. Add a file or connect a folder. **Jobs** shows queued/processing/completed work
   and extraction errors; select unfinished work to cancel, or failed/cancelled
   work to retry.
5. Choose **Sessions → + New session**, select an ACP agent, and ask a question.

`:Aero knowledge` opens the same collection picker directly. The sidebar lists
space sessions below their owning spaces. Standard expand/collapse keys work on
the Knowledge base heading; session rename/stop/delete actions reuse Aero's
session lifecycle. `a` on a space or collection starts a scoped session.

Collection pickers include **Collection sessions** and **Search collection**.
Choose **Cross-collection research** at the knowledge entry point to explicitly
select broader scope. Cross-collection conversations are persisted separately;
they do not silently expand ordinary space or collection sessions.

### Add sources with the References finder

Source statuses distinguish extraction outcomes:

- `ready`: extraction succeeded without reported issues.
- `ready_with_warnings`: extraction succeeded, but has limitations or warnings
  (for example, cached spreadsheet values without charts or recalculated formulas).
  Extracted content is available; inspect **Extraction details** for the warnings.
- `needs_attention`: extraction failed or was cancelled; inspect the error and retry.
- `processing`: extraction is queued or running.

Previously indexed sources with warnings receive `ready_with_warnings` when the
catalog is loaded, without requiring re-extraction.

Choose **Browse sources → source → Extraction details** to open the source's
current metadata, status, errors, and warnings in the middle reader panel's
**Metadata** tab.
Use normal Neovim scrolling, search (`/`), and yank commands to inspect or copy
details; press `q` to return to the previous middle-panel view. Reopening details
refreshes the metadata in the same panel.

Choose **Browse sources → source → View extracted content** to read the full saved
extraction in the middle reader panel's **Extracted content** tab: text chunks with their source locations,
tables as JSON rows, the extraction version, and warnings. Normal scrolling,
search, and yank commands work; `q` returns to the previous middle-panel view.
Reopening refreshes the content in the same panel. Sources without a saved
extraction show a message directing you to details or retry; **Open** continues
to open the managed source document.

Knowledge uses the same reader-tab controls as Workspace, with **Extracted
content** and **Metadata** tabs for the selected source. Click the tab labels or
use `:Aero reader content` / `:Aero reader metadata` to switch; each tab retains
its cursor and scroll position. Opening either action populates the corresponding
tab, and selecting the other loads it automatically. Source selections are isolated
within each Neovim tab. `:Aero reader panes` can show both views as stacked panes;
`:Aero reader tabs` returns them to one middle window. Returning to a Workspace
restores its own reader tabs and selected document.

Choose **Add file** in a space to open the same filesystem finder used by
**References**, labeled **Source finder** with the destination collection/space.
It starts at the configured `reference_finder.home`.

| Finder key | Action |
| --- | --- |
| Enter / `l` | Enter a folder |
| `h` / `-` | Go to the parent folder |
| `y` | Mark a file or folder for copy |
| `d` | Mark a file or folder for cut |
| `u` | Unmark an item |
| `:w` | Stage the marked items in the lower panel |
| `q` / Escape | Finish and import the staged items into the space |

Visual selections can mark several rows at once. **Use `:w` before `q`: unstaged
marks are not imported.** Imported folder paths remain visible in Browse sources,
and extraction starts automatically. The destination stays pinned while the
finder is open. Transfer errors retain the staged items so the operation can be
retried.

### Scope and selection

In a Knowledge base chat composer, type `/source` on its own line and press Enter
to choose a source, or `/tag` to choose all sources carrying a tag. Source choices
show their tags. These shortcuts replace the session's active source selection;
choose **All sources** to reset it. The rest of your draft is preserved. Both
commands are available only in Knowledge base sessions.

The panel title shows **Ask this space**, **Ask this collection**, or the selected
collections, whether the session uses all or selected sources, and the tags attached
to those active sources (or **Tags: none**). Tags describe the active sources, not
a live tag filter: choosing a tag selects the matching files at that moment.

| Command | Action |
| --- | --- |
| `:Aero knowledge scope` | Choose files, a connected folder, a tag, or a saved source set |
| `:Aero knowledge status` | Show the current session's scope, source tags, and full active source list |
| `:Aero knowledge set` | Save the current space session's selected files as a named source set |
| `:'<,'>Aero knowledge selection` | Append selected text and its file/line location to the selected knowledge session's draft |
| `:'<,'>Aero knowledge note` | Deliberately preserve selected text as an editable space note |

Without a range, selection/note commands use the current buffer. Finish the current
agent turn before changing scope. Choose **Edit tags** in the source browser to
open a regular buffer with one tag per line. Add, edit, or delete lines with normal
Vim commands, then use `:w` to save. An empty buffer clears all tags; commas are
literal tag text. Unsaved edits are retained when switching buffers.
Moving the cursor onto a tag line automatically shows a read-only source preview
in a normal split window on the right. It updates as you move between tags.
Press Enter on a tag (or use `<C-w>l`) to focus the source window, navigate with `j`/`k`, and press Enter to
open the selected source. Use `<C-w>h` to return to the tags. The list includes sources in the
same space and uses saved tags, so save edits first
to include them in the results.
Source rows
in the sidebar and **Browse sources** show their
tags as `#pricing #important`; sidebar tags use the `AeroTag` highlight group.
Choose **Tags** in a space's action menu to see all source tags used in that space,
sorted alphabetically with source counts. Select a tag to browse its matching
sources; this does not change any session's scope.
The sidebar also includes an expandable **Tags** group under each space. Tags
are alphabetized and show source counts; expand a tag to see its sources and
press Enter on a source for its actions.
Search results identify the space, source version, and
supporting location. Selecting a result opens its supporting text. Historical
citations retain access to the extracted version and archived text.

Agents receive citation URIs with the evidence returned by search/read. Markdown
links using those URIs open the exact retained chunk: press Enter on a citation
in a Neovim transcript to inspect its source version,
location, and extraction issues. Permission choices still take precedence over
citation navigation in transcripts.

ACP knowledge sessions receive an `aero_knowledge` MCP tool. It supports source
listing, hybrid search, chunk/document reading, table reading and aggregation,
curated notes, pinning, and extraction job controls.
The host binds tool access to the session's scope; request arguments can narrow
that scope. Existing provider configuration, transcript persistence, drafts,
permissions, and model controls remain the normal Aero mechanisms.

### Agent context budgets

Extraction is cached locally, not attached to every prompt. Agent tool responses
use progressive disclosure; the reader UI retains the full extracted content.

- `search` returns five excerpts by default (maximum 20), each at most 600
  characters. `total_results` reports the number of matches. Narrow the query or
  source selection when more matches exist. Excerpts retain source locations,
  versions, and citation URIs; `truncated` indicates omitted surrounding text.
- `read` defaults to one chunk, accepts at most ten chunks per call, and returns
  at most 12,000 text characters. Continue using `next_chunk` as `first` and
  `next_offset` as `offset` (zero when absent), retaining `version`.
- `read_note` returns at most 12,000 body characters. Continue with `next_offset`.
- `list` returns compact source/note summaries, 20 items by default (maximum
  100). Continue with `next_offset`; `total_items` counts matching items.
- `table` returns 20 rows by default (maximum 100), within a 12,000-character
  serialized-row budget. Continue with `next_row` as `first`. An oversized row
  is returned as a JSON `row_fragment`; concatenate successive fragments using
  `next_offset` before parsing that row. Use `aggregate` for numerical summaries
  without sending the underlying rows to the agent.

Offsets count Unicode characters, not bytes. These are evidence-text budgets,
not exact token limits; JSON metadata adds overhead. Search distinguishes usable
sources with coverage warnings from incomplete extraction, reporting counts and
at most five source details for each category.

## Sources, extraction, and updates

Sources are stored as managed copies. Finder **copy** keeps the original; **cut**
removes it only after its managed files and catalog entries have been saved.
Connected folders are initially scanned and checked every 60 seconds by default.
**Sync folders** runs the same change detection immediately. Files keep their relative
folder names in metadata. Extraction runs in a bounded background queue.

| Format | Extracted evidence | Coverage limits |
| --- | --- | --- |
| Markdown / UTF-8 text | Text chunks, lines, headings | Text only |
| CSV | Exact parsed rows, columns, multiline/quoted cells | Numeric operations use actual rows |
| PDF | Page text; OCR on empty scanned pages when available | Images/diagrams need visual inspection; OCR may be uncertain |
| XLSX | OfficeCLI worksheet values, sparse rows/columns, supported formula results | Unsupported formulas use cached values when available; charts/images are not visually interpreted |
| PPTX | OfficeCLI slide text, tables, and speaker notes | Charts, images, and diagrams are not visually interpreted |
| DOCX | OfficeCLI body paragraphs and tables with element paths | Headers, footers, comments, and visual content are not included; page numbers are not inferred |
| PNG / JPEG / TIFF / BMP / WebP | OCR text | Recognition may be uncertain; visual content is not described |

PDF extraction requires Poppler's `pdftotext`; scanned-page OCR additionally uses
`pdftoppm` and Tesseract. Markdown and CSV parsing are built into the native
`aero-mcp` helper. XLSX, PPTX, and DOCX extraction invokes the installed `officecli`
executable on the Neovim process's `PATH` using structured JSON output. No Python
runtime is required. Image OCR requires Tesseract
(`brew install tesseract` on macOS);
actual image codec support depends on the installed Tesseract build.
Missing tools and unsupported files receive `needs_attention`; successful partial
extraction receives `ready_with_warnings`. After installing a missing tool, use
**Retry extraction** on an existing source.

Office sources are read from temporary copies with the correct filename suffix;
managed originals are not modified. Aero converts OfficeCLI's structured nodes
into the standard chunks/tables/issues payload. Word and PowerPoint evidence
retains OfficeCLI element paths, and PowerPoint also retains slide numbers.
Spreadsheet tables preserve sheet names and row/column positions. When OfficeCLI
can evaluate a formula, its computed value is used; otherwise a cached value is
used with a warning, or an unavailable result is left empty with a warning.
Differences between cached and computed values are reported. Office extraction
also reports its coverage limits as `ready_with_warnings`.

Install OfficeCLI before indexing these formats, and retry existing sources after
installing it. Legacy binary `.doc`, `.xls`, and `.ppt` files are not registered;
convert them to `.docx`, `.xlsx`, or `.pptx`, or configure a custom extractor.

The managed copy changes only on explicit refresh or connected-folder sync.
Earlier raw content and extraction versions are retained. Notes that
reference older source versions are labeled potentially stale. **What changed?**
lists recently imported/reprocessed sources and affected notes.

Connected-folder scans skip symlinks, scan at most 20 directory levels, and currently
consider the supported source extensions. A connected folder cannot contain or
be inside Aero's own managed knowledge directory.
Finder imports accept regular files and folders containing files; symbolic links
are rejected. They preserve relative paths and reject existing top-level source
names and overlapping selections before copying or cutting material.

### Optional semantic retrieval

Keyword search works without a model dependency. To add semantic retrieval,
configure an embedding adapter executable. It receives JSON on stdin:

```json
{ "texts": ["Text to embed"] }
```

It must return a model identity and one finite, consistently sized vector per
input text:

```json
{ "model": "your-model-id", "vectors": [[0.12, 0.34, 0.56]] }
```

The same adapter is used for ingestion and queries. Matching model identities are
required for cosine similarity; source embeddings are retained in the rebuildable
extraction cache. Re-extract existing sources after configuring/changing the
adapter. Query embedding runs asynchronously; failures fall back to keyword
search. No embedding model is downloaded automatically.

### Custom extractors

Extractors are command-based plugins, written in any language. Register file
extensions and an executable argument list in `knowledge.extractors`:

```lua
require("aero").setup({
  knowledge = {
    extractors = {
      {
        extensions = { ".json" },
        command = { "/absolute/path/to/json-extractor" },
      },
    },
  },
})
```

Use lowercase extensions with a leading dot. Custom adapters take precedence over
built-ins, so the same mechanism can replace spreadsheet extraction or image OCR.
Each extension may appear in only one custom adapter. Connected-folder scans also
include registered extensions. Commands run on the Neovim host without a shell;
use absolute script paths rather than `~` or shell substitutions.

Aero's Go helper launches the configured command as a separate process; it does
not interpret the script itself. For example, `command = { "node", "/path/to/extractor.cjs" }`
uses the `node` executable on the Neovim process's `PATH`. Node.js must already be
installed; Aero does not install or bundle language runtimes. An absolute runtime
path such as `/opt/homebrew/bin/node` also works. Specify the runtime explicitly:
Aero does not infer it from the script's file extension. Compiled executables can
run directly without a separate language runtime.

The adapter receives one JSON object on stdin (protocol version 1):

```json
{
  "protocol_version": 1,
  "path": "/absolute/managed/source/path",
  "name": "original-name.json",
  "extension": ".json"
}
```

Stdin contains request metadata, **not the source file's contents**. The helper
writes the JSON request and closes stdin. The extractor parses that request, then
reads the source file separately using `path`. This JSON interface is identical
for every implementation language.

Managed copies have extensionless paths: use `name` or `extension` to determine
the format. Return exactly one JSON object on stdout; send diagnostics to stderr.
All adapters, including built-ins, use this payload:

```json
{
  "chunks": [{ "text": "Extracted evidence", "location": { "section": "Introduction" } }],
  "tables": [{ "name": "Measurements", "rows": [["label", "value"], ["A", "12"]] }],
  "issues": []
}
```

All three arrays are required (empty arrays are valid). Chunk text must be
nonempty; `location` is an object with string or finite numeric values. Standard
`line`, `end_line`, `page`, `slide`, and `row` fields are positive, one-based
integers. Other location fields can identify sections, images, timestamps, or
format-specific evidence. Table cells are strings, including numeric values;
preserve sparse rows/columns with empty arrays/strings. Issues are warning strings
and cause `ready_with_warnings` on successful extraction.

#### Node.js example

Save this minimal UTF-8 text extractor as `extractor.cjs`. The `.cjs` extension
lets Node.js run it as CommonJS regardless of nearby package settings:

```javascript
const fs = require("node:fs");

try {
  const request = JSON.parse(fs.readFileSync(0, "utf8"));

  if (request.protocol_version !== 1) {
    throw new Error("Unsupported extractor protocol");
  }

  const text = fs.readFileSync(request.path, "utf8");

  process.stdout.write(JSON.stringify({
    chunks: text.trim()
      ? [{ text, location: { section: "document" } }]
      : [],
    tables: [],
    issues: [],
  }));
} catch (error) {
  console.error(error.message);
  process.exitCode = 1;
}
```

In `JSON.parse(fs.readFileSync(0, "utf8"))`:

- `0` is the file descriptor for **stdin**.
- `fs.readFileSync(0, "utf8")` reads the incoming JSON text until stdin closes.
- `JSON.parse(...)` converts that text into the JavaScript `request` object.
- `request.path`, `request.name`, `request.extension`, and
  `request.protocol_version` expose the fields shown above.

The next read, `fs.readFileSync(request.path, "utf8")`, reads the actual source
file. `process.stdout.write(...)` returns the result to Aero; `console.error(...)`
sends failure details to stderr, and a nonzero exit status marks extraction failed.
Keep logs off stdout so the result remains valid JSON.

Register it for a UTF-8 text-based custom format:

```lua
require("aero").setup({
  knowledge = {
    extractors = {
      {
        extensions = { ".custom" },
        command = { "node", "/absolute/path/to/extractor.cjs" },
      },
    },
  },
})
```

This example reads text directly. For binary or structured formats, replace the
source-reading/parsing logic while keeping the same input/output JSON contract.

#### Go example

For example, a minimal JSON extractor written in Go (build it with
`go build -o json-extractor main.go`):

```go
package main

import (
    "encoding/json"
    "fmt"
    "os"
)

func extract() error {
    var request struct {
        ProtocolVersion int `json:"protocol_version"`
        Path string `json:"path"`
    }
    if err := json.NewDecoder(os.Stdin).Decode(&request); err != nil { return err }
    if request.ProtocolVersion != 1 { return fmt.Errorf("unsupported protocol") }
    data, err := os.ReadFile(request.Path)
    if err != nil { return err }
    var compact json.RawMessage
    if err := json.Unmarshal(data, &compact); err != nil { return err }
    return json.NewEncoder(os.Stdout).Encode(map[string]any{
        "chunks": []any{map[string]any{
            "text": string(compact), "location": map[string]any{"section": "document"},
        }},
        "tables": []any{}, "issues": []string{},
    })
}

func main() {
    if err := extract(); err != nil {
        fmt.Fprintln(os.Stderr, err)
        os.Exit(1)
    }
}
```

The core validates output, computes the source's SHA-256 version, and applies the
optional embedding adapter afterward. Extractors do not supply versions or vectors.
Nonzero exit codes, invalid output, missing executables, and the 120-second adapter
timeout fail the extraction job with visible error details. Existing ingestion
concurrency and cancellation apply to custom adapters too. Re-extract sources
after changing adapters; source versions identify raw content, not adapter
implementations. No automatic plugin installation is performed.

Built-in adapters in `apps/mcp/internal/knowledge/` follow the same contract:
register a Go handler in the `builtins` map, return a `Document`, and add the
extension to the connected-folder filter in `lua/aero/knowledge.lua`.
Custom commands need no core code changes or Go compiler at runtime.

The ingestion queue invokes `aero-mcp extract PATH ORIGINAL_NAME`, passing options
on stdin and receiving the cached document JSON on stdout. Rebuild the helper
with `make build-mcp` after updating a development checkout. The former
`knowledge.python` option is no longer used.

## Notes

**Notes** opens deliberately saved findings; edit a note and use `:w` to create a
new revision. Concurrent edits are revision-checked. Pinning is explicit. Saved
notes are searchable in later sessions, with their citations and stale-evidence
state; synthesis is not treated as independent corroboration of its sources.

## Configuration

```lua
require("aero").setup({
  knowledge = {
    executable = false, -- prefer the checkout build, or configure an updated aero-mcp path
    ingest_concurrency = 2,
    sync_interval = 60000, -- milliseconds; 0 disables periodic folder scans
    embedding_command = {}, -- your adapter executable and arguments
    extractors = {}, -- { { extensions = { ".ext" }, command = { "executable", "arg" } } }
  },
})
```

Extraction jobs retain errors and can be retried after failure or cancellation.
On restart, work whose owner process is gone becomes explicitly retryable rather
than being silently reported as complete.

## Persistence and verification

Knowledge lives beside the configured `state_file`, under `knowledge/`:

```text
catalog.json                    versioned catalog, ownership, jobs, source sets
spaces/<id>/sources/<source-id>  managed current source copies
spaces/<id>/notes/              retained note revisions
collections/<id>/              collection conversation working directories
research/<id>/                 explicitly selected cross-collection conversations
cache/<source-id>/<version>.json extracted text, tables, locations, optional vectors
history/<source-id>/<version>   retained older raw source content
```

Catalog updates reuse Aero's cross-process state lock and atomic replacement.
Stable IDs survive renaming. Raw copies/extraction indexes and catalog replacement
are separate filesystem operations; a failed catalog write can leave an
unreferenced directory/file. Automatic garbage collection is not implemented, and
retained source history currently has no expiration policy.

Run `make test-knowledge` for storage, extraction, retrieval, queue, note,
scope, and session tests.

The initial UI uses the existing sidebar and pickers rather than the proposed
dedicated three-pane space workbench. Richer citation chips and visual PDF passage
highlighting, a large-scale indexed search service, and multi-user
sharing/synchronization remain follow-up work.
## Shared source and note tags

Sources and notes share tag names within a space. Open **Notes**, choose a note,
and select **Edit tags**, or press `gt` in an open note. Enter one tag per line
and use `:w` to save. Save a new note before tagging it. The tag editor previews
matching sources and notes; Enter focuses the preview so you can open an item.
The space's **Tags** group includes both kinds of item.

Agents can discover tags with `aero_knowledge`'s `list` action and request an exact
registered tag with `{ "action": "list", "tag": "offline" }`. Results include
matching sources and notes in the session's scope. Agents then use `read` or
`read_note` to inspect them. Source-selected sessions still require all of a
note's evidence to belong to the selected sources; sharing a tag does not widen
that scope. Note tags persist across body revisions.
