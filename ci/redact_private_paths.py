#!/usr/bin/env python3
"""Rewrite private games_module source paths embedded in a packaged binary.

The Windows export links a prebuilt engine. Debug strings in that engine can
name the private repo and its modules. This keeps each C string the same
length and replaces the directory with ./<basename>.
"""

from __future__ import annotations

import sys
from pathlib import Path

MARKER = b"games_module"


def _basename(text: bytes) -> bytes:
    base = text.replace(b"\\", b"/").rsplit(b"/", 1)[-1]
    if not base or MARKER in base or base in (b".", b".."):
        return b"redacted"
    return base


def _rewrite(text: bytes) -> bytes:
    base = _basename(text)
    repl = b"./" + base
    if len(repl) > len(text):
        repl = b"." * len(text)
    else:
        repl = repl + b"." * (len(text) - len(repl))
    return repl


def _redact_ascii(buf: bytearray) -> None:
    start = 0
    while True:
        found = buf.find(MARKER, start)
        if found < 0:
            return
        begin = found
        while begin > 0 and buf[begin - 1] not in (0, 10, 13) and 32 <= buf[begin - 1] < 127:
            begin -= 1
        end = found
        while end < len(buf) and buf[end] != 0:
            end += 1
            if end - begin > 4096:
                break
        if end <= begin or MARKER not in buf[begin:end]:
            start = found + len(MARKER)
            continue
        buf[begin:end] = _rewrite(bytes(buf[begin:end]))
        start = end + 1


def _redact_utf16(buf: bytearray) -> None:
    marker = b"".join(bytes((byte, 0)) for byte in MARKER)
    start = 0
    while True:
        found = buf.find(marker, start)
        if found < 0:
            return
        begin = found
        while begin >= 2:
            pair = buf[begin - 2 : begin]
            if pair[1] != 0 or pair[0] in (0, 10, 13) or not 32 <= pair[0] < 127:
                break
            begin -= 2
        end = found
        while end + 1 < len(buf):
            pair = buf[end : end + 2]
            if pair[0] == 0 and pair[1] == 0:
                break
            if pair[1] != 0 or not 32 <= pair[0] < 127:
                break
            end += 2
            if end - begin > 8192:
                break
        encoded = bytes(buf[begin:end])
        chars = bytes(encoded[0::2])
        if MARKER not in chars:
            start = found + len(marker)
            continue
        rewritten = _rewrite(chars)
        wide = bytearray()
        for byte in rewritten:
            wide.extend((byte, 0))
        if len(wide) == end - begin:
            buf[begin:end] = wide
        start = end + 2


def redact(data: bytes) -> bytes:
    buf = bytearray(data)
    _redact_ascii(buf)
    _redact_utf16(buf)
    if len(buf) != len(data):
        raise RuntimeError("redaction changed the file size")
    return bytes(buf)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: redact_private_paths.py <binary>", file=sys.stderr)
        return 2
    path = Path(argv[1])
    original = path.read_bytes()
    updated = redact(original)
    if updated != original:
        path.write_bytes(updated)
        print(f"redacted private paths in {path}")
    else:
        print(f"no private games_module paths in {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
