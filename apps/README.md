# Aero host tools

This directory is the Go monorepo for Aero's host-side adapters. `go.work`
connects two independently buildable modules:

- `mcp/`: `aero-mcp`, the agent task MCP server.
- `companion/`: `aero-companion`, the mobile web bridge with its frontend under
  `companion/web/`.

`scripts/` packages both tools into the ignored `dist/` directory. The shared
version comes from `../release.json`; root Makefile commands build and test the
workspace.

From the repository root:

```sh
make build-all
make check-all
make release
```

From this directory, after building the companion frontend:

```sh
go test ./mcp/... ./companion/...
```

See [development and releases](../docs/releasing.md) for requirements and
publishing instructions.
