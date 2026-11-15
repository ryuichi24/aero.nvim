# Lua verification

Run from the repository root:

- `make test-lua-unit`: isolated module tests; requires Neovim only.
- `make test-lua`: build the local hosts and run the complete fixture suite.
- `python3 tests/run.py <name> ...`: select tests by filename stem, including nested tests.
- `python3 tests/run.py --real-agent`: also run the opt-in real-agent smoke test.

`unit/acp/` and `unit/session/` contain focused ownership, state-transition, and
effect-order tests. `unit/module_boundaries.lua` checks that domain modules do not
load their presentation layers. Existing cross-feature behavioral tests remain at
the top level to preserve their documented direct invocation paths.

The runner discovers Lua tests recursively, excludes `fixtures/`, and runs each
test in its own Neovim process. Tests under `unit/` are automatically included in
the unit suite; the legacy top-level unit allowlist remains supported.
