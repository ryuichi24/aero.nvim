"""Build both workspace modules with one release version and checksum manifest."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tarfile

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--tag", help="Require a published manifest matching this tag")
args = parser.parse_args()
manifest = json.loads((root.parent / "release.json").read_text())
version = manifest["version"]
if not re.fullmatch(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?", version):
    raise SystemExit("Invalid release version")
if args.tag and (not manifest["published"] or args.tag != "v" + version):
    raise SystemExit("Release tag must match a published root release.json")

go = os.environ.get("GO", "go")
dist = root / "dist"
dist.mkdir(exist_ok=True)
assets = []
# Keep Windows MCP cross-build coverage; Unix transports remain macOS/Linux only.
targets = manifest["platforms"] + ["windows-amd64"]
for target in targets:
    if target not in {"darwin-arm64", "darwin-amd64", "linux-arm64", "linux-amd64", "windows-amd64"}:
        raise SystemExit(f"Unsupported release target: {target}")
    system, arch = target.split("-")
    env = dict(os.environ, CGO_ENABLED="0", GOOS=system, GOARCH=arch)
    for module, executable, package in (
        ("mcp", "aero-mcp", "./cmd/aero-mcp"),
        ("companion", "aero-companion", "."),
    ):
        if module == "companion" and system == "windows":
            continue
        suffix = ".exe" if system == "windows" else ""
        output = dist / f"{executable}-{version}-{target}{suffix}"
        subprocess.run(
            [go, "build", "-trimpath", "-ldflags", f"-s -w -X main.version={version}",
             "-o", str(output), package], cwd=root / module, env=env, check=True,
        )
        assets.append(output)

subprocess.run([sys.executable, str(root / "scripts/companion-licenses.py"),
                str(dist / "AERO_COMPANION_THIRD_PARTY_LICENSES.tar.gz")], check=True)
# Workspace module listings include both local modules; only archive external deps.
listing = subprocess.check_output([go, "list", "-m", "-json", "all"], cwd=root, text=True)
decoder = json.JSONDecoder()
modules = []
while listing.strip():
    module, end = decoder.raw_decode(listing.lstrip())
    listing = listing.lstrip()[end:]
    modules.append(module)
(dist / "DEPENDENCIES.txt").write_text("".join(
    f"{module['Path']} {module.get('Version', '(workspace)')}\n" for module in modules
))
with tarfile.open(dist / "THIRD_PARTY_LICENSES.tar.gz", "w:gz") as archive:
    archive.add(root.parent / "LICENSE", arcname="Aero/LICENSE")
    for module in modules:
        if module.get("Main") or not module.get("Dir"):
            continue
        directory = Path(module["Dir"])
        for path in sorted(directory.iterdir()):
            if path.is_file() and path.name.lower().startswith(("license", "licence", "copying", "notice")):
                archive.add(path, arcname=f"{module['Path']}@{module.get('Version', '')}/{path.name}")
(dist / "SHA256SUMS").write_text("".join(
    f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in sorted(assets)
))
print(f"Packaged {len(assets)} binaries for Aero v{version} in {dist}")
