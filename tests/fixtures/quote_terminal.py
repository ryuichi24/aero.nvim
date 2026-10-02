"""Capture bracketed pastes from a terminal agent without treating newlines as submit."""
import json
import os
import sys
import tty

tty.setraw(sys.stdin.fileno())
sys.stdout.write("\x1b[?2004hterminal log text\r\n")
sys.stdout.flush()
pastes = []
pending = b""


def save():
    with open(sys.argv[1], "w") as output:
        json.dump({"pastes": pastes, "pending": pending.decode("utf-8", errors="replace")}, output)


save()
while True:
    chunk = os.read(sys.stdin.fileno(), 4096)
    if not chunk:
        break
    pending += chunk
    while b"\x1b[200~" in pending and b"\x1b[201~" in pending:
        before, rest = pending.split(b"\x1b[200~", 1)
        text, pending = rest.split(b"\x1b[201~", 1)
        assert not before, "input was sent outside bracketed paste"
        pastes.append(text.decode("utf-8"))
    save()
