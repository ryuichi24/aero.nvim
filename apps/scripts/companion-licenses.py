"""Bundle license notices and package metadata for the embedded frontend."""

from pathlib import Path
import tarfile
import sys

root = Path(__file__).resolve().parents[1]
modules = root / "companion/web/node_modules/.pnpm"
output = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "companion/dist/AERO_COMPANION_THIRD_PARTY_LICENSES.tar.gz"

if not modules.is_dir():
    raise SystemExit("Install companion frontend dependencies with pnpm first")

with tarfile.open(output, "w:gz") as archive:
    archive.add(root.parent / "LICENSE", arcname="Aero/LICENSE")
    for path in sorted(modules.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        name = path.name.lower()
        if name == "package.json" or name.startswith(("license", "licence", "copying", "notice")):
            archive.add(path, arcname=str(Path("frontend") / path.relative_to(modules)))
