# Agent Instructions

## Coding Conventions

Before writing or modifying code, read and follow
[Coding Conventions](./docs/dev/conventions/coding/init.md).

## Git Commits

Before creating a commit, read and follow
[Commit Conventions](./docs/dev/conventions/commit.md).

## Development checks

See `docs/releasing.md` for tool prerequisites and fresh-checkout setup.
After code changes, run `make format`, review the diff, and run `make lint`.
Fix failures and rerun affected checks after further edits. Run appropriate
behavioral tests; `make check-all` runs the complete local verification suite.

Install the native pre-commit hook with `make hooks` in each checkout after
reviewing any existing local hook. Never bypass hooks or claim checks passed
unless they actually ran successfully. Commit only when explicitly requested.
