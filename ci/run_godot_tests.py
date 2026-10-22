#!/usr/bin/env python3
"""Run the launcher's GDScript tests with a headless Godot 4.3 editor.

The check job has no Godot install. This downloads the official headless-capable
editor, checks its zip hash, and runs each test script with --headless.
"""

from __future__ import annotations

import hashlib
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RELEASE = "https://github.com/godotengine/godot/releases/download/4.3-stable"
ASSETS = {
    "Windows": {
        "name": "Godot_v4.3-stable_win64.exe.zip",
        "sha256": "8f2c75b734bd956027ae3ca92c41f78b5d5a255dacc0f20e4e3c523c545ad410",
        "prefer": "Godot_v4.3-stable_win64_console.exe",
        "fallback": "Godot_v4.3-stable_win64.exe",
    },
    "Linux": {
        "name": "Godot_v4.3-stable_linux.x86_64.zip",
        "sha256": "7de56444b130b10af84d19c7e0cf63cf9e9937ee4ba94364c3b7dd114253ca21",
        "prefer": "Godot_v4.3-stable_linux.x86_64",
        "fallback": "Godot_v4.3-stable_linux.x86_64",
    },
}
SCRIPTS = [
    "res://tests/mod_install.gd",
    "res://tests/behavior.gd",
]


def _asset() -> dict[str, str]:
    system = platform.system()
    if system not in ASSETS:
        raise SystemExit(f"no headless Godot asset for {system}")
    return ASSETS[system]


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _godot_binary() -> Path:
    spec = _asset()
    cache = Path(tempfile.gettempdir()) / "blazium-godot-4.3"
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / spec["name"]
    if not archive.is_file() or _sha256(archive) != spec["sha256"]:
        url = f"{RELEASE}/{spec['name']}"
        print(f"Downloading {url}")
        urllib.request.urlretrieve(url, archive)
        got = _sha256(archive)
        if got != spec["sha256"]:
            archive.unlink(missing_ok=True)
            raise SystemExit(f"Godot zip hash mismatch: {got}")
    dest = cache / "editor"
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir()
    with zipfile.ZipFile(archive) as zipped:
        zipped.extractall(dest)
    names = {path.name: path for path in dest.rglob("*") if path.is_file()}
    chosen = names.get(spec["prefer"]) or names.get(spec["fallback"])
    if chosen is None:
        raise SystemExit(f"Godot zip has no editor binary: {sorted(names)}")
    chosen.chmod(chosen.stat().st_mode | stat.S_IEXEC)
    return chosen


def main() -> int:
    binary = _godot_binary()
    failed = False
    for script in SCRIPTS:
        print(f"Running {script}")
        proc = subprocess.run(
            [str(binary), "--headless", "--path", str(ROOT), "--script", script],
            cwd=ROOT,
            check=False,
        )
        if proc.returncode != 0:
            print(f"{script} failed with exit {proc.returncode}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
