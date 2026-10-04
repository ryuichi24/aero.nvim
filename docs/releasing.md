# Releasing the MCP server

The [Task MCP adapter workflow](../.github/workflows/mcp.yml) builds and uploads
standalone MCP server executables when a Git tag matching `v*` is pushed.
There is no manual workflow trigger. Pull requests affecting `mcp/` or the
workflow run checks without publishing a release.

## Prepare the release

1. Update `mcp/release.json`:
   - Set `version` to the release version, for example `0.1.0`.
   - Set `published` to `true`.
   - Ensure the bridge protocol value matches the released server and Lua bridge.
2. From the repository root, run `make check` with Go 1.24 or newer installed.
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

Watch **Task MCP adapter** in the repository's Actions tab, or use `gh run list`
and `gh run watch <run-id>`.

CI runs `go test -race ./...` and `go vet ./...`, then builds:

- macOS: ARM64 and AMD64.
- Linux: ARM64 and AMD64.
- Windows: AMD64 (`.exe`; a packaging check, not Windows bridge support).

The release assets include `aero-mcp-<version>-<os>-<arch>` executables (with
`.exe` for Windows), `SHA256SUMS`, `DEPENDENCIES.txt`, and
`THIRD_PARTY_LICENSES.tar.gz`.

After CI succeeds, inspect the draft release and confirm the assets are attached:

```sh
gh release view v0.1.0
gh release edit v0.1.0 --draft=false
```

Users can then install the exact manifest version with `:Aero tasks install`.
The installer verifies the executable against `SHA256SUMS`. See
[agent task integration](agent-tasks.md#setup) for installation setup.

## Troubleshooting

- **Manifest validation fails:** check that `published` is `true` and that
  `"v" + version` exactly matches the pushed tag.
- **Asset upload fails because the release is missing:** create the GitHub
  Release for the existing tag, then rerun the failed job in GitHub Actions.
- **Checks or builds fail:** fix the underlying issue before publishing. Release
  assets are uploaded only after the check job succeeds.

Rerunning the release job uploads with `--clobber`, replacing assets with matching
names on that release.
