#!/usr/bin/env python3
"""Run each Lua behavioral test in an isolated Neovim process.

The real-agent smoke test is opt-in; the regular suite uses local fixtures only.
Run from the repository root, optionally passing test names without extensions.
"""

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

UNIT_TESTS = {"local_commands", "reveal", "listeners", "dashboard_subscriptions", "state_transactions"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tests", nargs="*", help="test names (default: all fixture tests)")
    parser.add_argument("--real-agent", action="store_true", help="include opencode smoke test")
    parser.add_argument("--unit", action="store_true", help="run isolated module tests; only Neovim is required")
    parser.add_argument("--timeout", type=int, default=180, help="timeout per script in seconds")
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    tests = sorted((root / "tests").glob("*.lua"))
    if args.unit and args.real_agent:
        parser.error("--unit cannot be combined with --real-agent")
    if args.unit:
        tests = [test for test in tests if test.stem in UNIT_TESTS]
    if args.tests:
        requested = {Path(name).stem for name in args.tests}
        unknown = requested - {test.stem for test in tests}
        if unknown:
            parser.error("unknown tests: " + ", ".join(sorted(unknown)))
        tests = [test for test in tests if test.stem in requested]
    elif not args.real_agent:
        tests = [test for test in tests if test.stem != "opencode"]

    for executable in (("nvim",) if args.unit else ("nvim", "git", "python3", "yq")):
        if not shutil.which(executable):
            parser.error(f"missing prerequisite: {executable}")
    if not args.unit:
        yq = subprocess.run(["yq", "--version"], capture_output=True, text=True, check=True)
        if "mikefarah/yq" not in yq.stdout or "version v4." not in yq.stdout:
            parser.error("task tests require Mike Farah's yq v4")

    env = os.environ.copy()
    if env.get("AERO_SKIP_IMAGE_INTEGRATION") == "1":
        skipped = [test for test in tests if test.stem == "mermaid_spacing"]
        tests = [test for test in tests if test.stem != "mermaid_spacing"]
        for test in skipped:
            print(f"SKIP {test.relative_to(root).as_posix()} (image integration disabled)", flush=True)
    env.setdefault("AERO_MCP_EXECUTABLE", str(root / "apps/mcp/aero-mcp"))
    for binary in (() if args.unit else (Path(env["AERO_MCP_EXECUTABLE"]), root / "apps/companion/aero-companion")):
        if not os.access(binary, os.X_OK):
            parser.error(f"build host tools with make build-all first: {binary}")

    failures = []
    for test in tests:
        relative = test.relative_to(root).as_posix()
        command = ["nvim", "--headless", "-u", "NONE", "-i", "NONE"]
        # These tests need Neovim's normal input loop for completion/command windows.
        command += ["-c", f"luafile {relative}"] if test.stem in {"prompt_paths_inline", "tasks_cmdwin"} else ["-l", relative]
        print(f"RUN {relative}", flush=True)
        try:
            result = subprocess.run(command, cwd=root, env=env, timeout=args.timeout)
            if result.returncode:
                failures.append(relative)
        except subprocess.TimeoutExpired:
            print(f"TIMEOUT {relative}", file=sys.stderr)
            failures.append(relative)
    print(f"Lua suite: {len(tests) - len(failures)}/{len(tests)} passed", flush=True)
    if failures:
        print("Failed: " + ", ".join(failures), file=sys.stderr)
    return bool(failures)


if __name__ == "__main__":
    sys.exit(main())
