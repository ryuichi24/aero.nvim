# Developing and releasing Aero's host tools

The [CI workflow](../.github/workflows/ci.yml) validates and packages both
`aero-mcp` and `aero-companion` on pull requests and branch pushes affecting host
tools, Lua integration, tests, or build tooling. When a Git tag matching `v*` is
pushed, the [Release workflow](../.github/workflows/release.yml) uploads the
artifacts from successful branch-push CI for that exact commit. It does not
repeat the tests or builds.

## Monorepo development

All host-tool source and build scripts live under `apps/`. The `apps/go.work`
workspace includes `apps/mcp/` and `apps/companion/`, each with its own `go.mod`.
Both executables share the root `release.json` version and the plugin's release
tag. Their executable names and Lua configuration options remain independent.
The MCP module can be built without Node.js or pnpm.

From the repository root:

```sh
make build-mcp       # Go + Python; same as make build
make build-companion # Go + Python + Node.js + pnpm; embeds the frontend
make build-all       # both native executables
make check-all       # both modules, Neovim integration, and frontend tests
go -C apps test ./mcp/... ./companion/... # build frontend first for Go embed
make release         # build UI and package cross-platform assets into apps/dist/
```

Use Go 1.24+, Node.js 24, and the pnpm version pinned in the frontend package.
Go commands run in workspace mode by default. To check module independence,
use `GOWORK=off go -C apps/mcp test ./...` or, after building the UI,
`GOWORK=off go -C apps/companion test ./...`.

`make release TAG=v0.4.0` also validates the tag against the published manifest.
CI uses the same packaging script, `apps/scripts/build-release.py`. The workspace
checksum file `apps/go.work.sum`, when generated, is tracked alongside module sums.

```text
apps/
  go.work
  go.work.sum
  mcp/              # MCP module and aero-mcp command
  companion/        # Companion module and embedded web frontend
  scripts/          # Shared release packaging
  dist/             # Generated release assets (ignored)
```

The root `release.json` remains the plugin-wide version manifest; the root
Makefile delegates builds into this workspace. Release asset names are unchanged.

## Formatting, linting, and local hooks

Install StyLua 2.6.0 (with LuaJIT syntax support) and Luacheck 1.2.0 on your
`PATH`, plus Git, Make, Go, Node.js, and pnpm. On macOS,
`brew install stylua luacheck` installs the Lua tools; verify their versions. `STYLUA`, `LUACHECK`,
`GO`, and `PNPM` can be overridden when invoking Make.

For a fresh checkout, run:

```sh
pnpm --dir apps/companion/web install --frozen-lockfile
make build-companion-ui # supplies assets required by Go embed
make hooks
make format
make lint
```

`make format` formats `lua/`, `plugin/`, `tests/`, and Lua tooling in `apps/scripts/`
with StyLua and the statement-spacing formatter, applies Go
lint fixes and gofumpt in both modules, and runs the frontend's existing
Prettier configuration. Review the resulting diff. `make lint` checks those
formats, runs Luacheck, Go vet, golangci-lint's `wsl_v5`, ESLint, and TypeScript
type checking. Per-language targets are `format-lua`, `format-go`, `format-web`,
`lint-lua`, `lint-go`, and `lint-web`.

Lua formatting adds a blank line before and after `if` blocks and `for` loops
when another statement is adjacent. Ordinary assignments, calls, and returns
stay together; blank lines between them are removed. Existing separators around
function declarations and comments are preserved. It does not add padding just
inside a block or between table fields / multiline arguments.
`apps/scripts/lua-spacing.lua` uses Neovim's Lua Tree-sitter parser to preserve
strings and comments, and refuses files with syntax errors. Neovim with the Lua
parser available is required for both formatting and linting (`NVIM_BIN` overrides
the executable). `make lint-lua` checks spacing without writing; the existing
pre-commit hook enforces it through `make lint`.

Lua files under `tests/` use a readability-oriented exception: preserve manual
blank lines, separate setup/action statements from consecutive `assert(...)`
groups, and separate individual `check(...)` fixture cases. The `if`/`for` rule
still applies. Spacing test fixtures use named cases and multiline Lua strings
so input and expected output can be compared directly.

Go tooling is pinned to golangci-lint v2.15.0 and downloaded through `go run`;
use a Go toolchain compatible with that release (verified with Go 1.27.3).
Frontend lint dependencies are pinned in `package.json` and `pnpm-lock.yaml`.
ESLint covers JS/MJS/TS/TSX files, including tests and Vite config, with
recommended JavaScript/TypeScript rules, strict equality, and React Hook rules.
Luacheck uses LuaJIT globals plus Neovim's `vim`; it permits shadowing,
discarded assigned values, unused method receivers, and empty branches.

`make hooks` copies `.githooks/pre-commit` to Git's effective hooks directory
and marks it executable. Reinstall after hook updates or in new checkouts.
Review any existing local pre-commit hook before replacing it. The hook runs
`make lint` against the whole working tree and blocks on failure; it does not
format or stage files. With partial staging, ensure the staged snapshot is
also consistent. Tests remain separate: run `make check-all` for full verification.

## Prepare the release

1. Update the root `release.json`:
   - Set `version` to the release version, for example `0.1.0`.
   - Set `published` to `true`.
   - Ensure the bridge protocol value matches the released server and Lua bridge.
2. From the repository root, run `make check-all` and
   `nvim --headless -u NONE -l tests/tasks_install.lua`.
3. Commit the manifest and any release changes. The tag must point to this commit.

The release job requires the tag to equal `v` followed by the manifest version:
version `0.1.0` requires tag `v0.1.0`.

## Trigger the pipeline

Authenticate the GitHub CLI with `gh auth login` if needed. You need permission to
push tags and create releases in the repository.

The workflow uploads assets to an existing GitHub Release; it does not create
one. Create a draft release before pushing the tag so it exists when CI reaches
the upload step. For example, from the repository root, after committing the
release changes:

```sh
git tag v0.1.0
gh release create v0.1.0 --draft --target "$(git rev-parse HEAD)" \
  --title "v0.1.0" --notes "Release notes go here."
git push origin v0.1.0
```

Replace `0.1.0` throughout with the chosen version. The explicit `--target`
ensures GitHub uses the release commit if it creates the remote tag before the
Git push. That commit must already be available on GitHub, so push your release
commit before running these commands. Creating the remote tag may itself trigger
the workflow; the draft release should be created before the upload job runs.

## Verify and publish

Watch **CI** and **Release** in the repository's Actions tab, or use `gh run list`
and `gh run watch <run-id>`. These are separate runs: CI performs the build;
Release waits up to one hour for CI, verifies binary checksums, and uploads its
artifacts. Branch and tag pushes can happen together.

CI runs race-enabled Go tests and vet for both modules, managed companion
Neovim tests, the MCP installer test, and frontend tests/format checks. It builds:

- macOS: ARM64 and AMD64.
- Linux: ARM64 and AMD64.
- Windows: MCP only, AMD64 (`.exe`; a packaging check, not Windows bridge support).

The release assets include:

- `aero-mcp-<version>-<os>-<arch>` (with `.exe` for Windows).
- `aero-companion-<version>-<os>-<arch>` with its frontend embedded.
- A single `SHA256SUMS` covering both binary families, compatible with the MCP
  installer.
- `DEPENDENCIES.txt` and `THIRD_PARTY_LICENSES.tar.gz` for Go dependencies.
- `AERO_COMPANION_THIRD_PARTY_LICENSES.tar.gz` for frontend notices and metadata.

Both binaries embed the same manifest version. The existing `bridge_protocol`
field describes MCP compatibility, not the companion's private protocol.

After CI succeeds, inspect the draft release and confirm the assets are attached:

```sh
gh release view v0.1.0
gh release edit v0.1.0 --draft=false
```

Users can then install the exact manifest version with `:Aero tasks install`.
The installer verifies the executable against `SHA256SUMS`. See
[agent task integration](agent-tasks.md#setup) for installation setup.
Companion users run `:Aero companion install` to download and verify the matching
binary from that same release; see
[companion installation](companion.md#install-from-neovim-recommended).

## Troubleshooting

- **Manifest validation fails:** check that `published` is `true` and that
  `"v" + version` exactly matches the pushed tag.
- **Asset upload fails because the release is missing:** create the GitHub
  Release for the existing tag, then rerun the failed job in GitHub Actions.
- **Checks or builds fail:** fix the underlying issue before publishing. Release
  assets are uploaded only after CI succeeds for the tagged commit. For a transient
  failure, rerun CI first, then rerun Release.
- **Release times out waiting for CI:** ensure the tagged commit was pushed to a
  branch and triggered CI. A pull-request run alone is not used for publishing.
- **CI artifacts have expired or been deleted:** rerun CI for the tagged commit to
  recreate them, then rerun Release.

Rerunning the release job uploads with `--clobber`, replacing assets with matching
names on that release. You can also retry an existing tag from the Release
workflow's **Run workflow** button, or with:

```sh
gh workflow run release.yml -f tag=v0.1.0
```
