"""Small Mermaid CLI stand-in for asynchronous preview lifecycle tests."""
import argparse
from pathlib import Path
import struct
import sys
import time
import zlib

parser = argparse.ArgumentParser()
parser.add_argument("-i")
parser.add_argument("-o")
args, _ = parser.parse_known_args()
source = Path(args.i).read_text()
time.sleep(0.08)
if "INVALID" in source:
    print("Parse error: invalid diagram", file=sys.stderr)
    sys.exit(1)
def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

header = struct.pack(">IIBBBBB", 160, 80, 8, 2, 0, 0, 0)
pixels = (b"\0" + b"\x20\x90\xe0" * 160) * 80
Path(args.o).write_bytes(
    b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
    + chunk(b"IDAT", zlib.compress(pixels)) + chunk(b"IEND", b"")
)
