#!/usr/bin/env python3
"""Download the pinned chauffeur archive and extract one verified binary.

packaging/chauffeur/pins.json is the trusted record. Each platform has an
exact version, the versioned archive URL, and the archive's SHA-256 as
published in checksums.json of the @blazium-games/cli npm package at that
version. The archive is fetched once into memory; the bytes that are hashed
are the bytes that are unzipped, and nothing is written before the hash
matches.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PINS = ROOT / "packaging" / "chauffeur" / "pins.json"
URL_TEMPLATE = "https://cdn.blazium.online/tools/chauffeur/{platform}/{version}/archive/default"
VERSION_RE = re.compile(r"[0-9]+(\.[0-9]+){1,3}([-+][0-9A-Za-z.-]+)?")
SHA256_RE = re.compile(r"[0-9a-f]{64}")
MAX_ATTEMPTS = 4
RETRY_SLEEP_SEC = 5


class PinError(Exception):
    pass


def load_pin(platform: str, pins_path: Path = PINS) -> tuple[str, str, str]:
    try:
        doc = json.loads(pins_path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise PinError(f"cannot read {pins_path}: {exc}") from exc
    entry = doc.get(platform) if isinstance(doc, dict) else None
    if not isinstance(entry, dict):
        raise PinError(f"{pins_path} has no entry for {platform}")
    version = str(entry.get("version") or "").strip()
    url = str(entry.get("url") or "").strip()
    sha = str(entry.get("sha256") or "").strip()
    if not VERSION_RE.fullmatch(version):
        raise PinError(f"pinned chauffeur version for {platform} is not an exact version")
    if url != URL_TEMPLATE.format(platform=platform, version=version):
        raise PinError(f"pinned chauffeur url for {platform} is not the versioned archive")
    if not SHA256_RE.fullmatch(sha):
        raise PinError(f"pinned chauffeur sha256 for {platform} is not lowercase hex SHA-256")
    return version, url, sha


def download_once(url: str, timeout: int = 180) -> bytes:
    """One complete response. Only transport failures are retried."""
    last: Exception | None = None
    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                return resp.read()
        except (urllib.error.URLError, OSError) as exc:
            last = exc
            print(f"attempt {attempt}/{MAX_ATTEMPTS}: {exc}", file=sys.stderr)
            if attempt < MAX_ATTEMPTS:
                time.sleep(RETRY_SLEEP_SEC)
    raise PinError(f"download failed: {last}")


def extract_member(archive: bytes, name: str) -> bytes:
    try:
        with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
            info = zipped.getinfo(name)
            if info.is_dir():
                raise PinError(f"archive member {name} is a directory")
            return zipped.read(info)
    except KeyError as exc:
        raise PinError(f"archive has no member {name}") from exc
    except zipfile.BadZipFile as exc:
        raise PinError(f"archive is not a zip: {exc}") from exc


def write_binary(data: bytes, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    part = out.with_name(out.name + ".part")
    part.write_bytes(data)
    part.chmod(0o755)
    os.replace(part, out)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True, help="pins.json key, e.g. linux-amd64")
    parser.add_argument("--name", required=True, choices=("chauffeur", "chauffeur.exe"))
    parser.add_argument("--out", required=True, help="Destination file path")
    args = parser.parse_args()

    try:
        version, url, sha = load_pin(args.platform)
        print(f"Fetching chauffeur {version} for {args.platform}: {url}")
        archive = download_once(url)
        got = hashlib.sha256(archive).hexdigest()
        if got != sha:
            raise PinError(
                f"chauffeur archive sha256 {got} does not match the pin {sha} for {args.platform}"
            )
        binary = extract_member(archive, args.name)
    except PinError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    write_binary(binary, Path(args.out))
    print(f"sha256 ok ({len(archive)} byte archive, {len(binary)} byte {args.name})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
