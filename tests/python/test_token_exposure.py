"""Owner-only launcher control tokens.

The Godot script exits 0 only when both token files are created owner-only,
a group or world readable token is not adopted, and that readable token cannot
focus the launcher or open a library or game link.
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PRELOAD_SRC = ROOT / "tests" / "token_exposure_preload.c"


def _godot() -> Path:
    spec = importlib.util.spec_from_file_location(
        "run_godot_tests", ROOT / "ci" / "run_godot_tests.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module._godot_binary()


def _preload() -> Path:
    library = Path(tempfile.gettempdir()) / "libtoken_exposure.so"
    compiled = subprocess.run(
        ["gcc", "-shared", "-fPIC", "-O2", "-o", str(library), str(PRELOAD_SRC), "-ldl"],
        cwd=ROOT,
        check=False,
        text=True,
        capture_output=True,
    )
    if compiled.returncode != 0:
        raise RuntimeError(compiled.stderr or compiled.stdout)
    return library


def test_control_tokens_are_owner_only() -> None:
    # umask 0 makes ordinary fopen/mkdir creation group and world accessible.
    os.umask(0)
    env = os.environ.copy()
    env["LD_PRELOAD"] = str(_preload())
    proc = subprocess.run(
        [
            str(_godot()),
            "--headless",
            "--path",
            str(ROOT),
            "--script",
            "res://tests/token_exposure.gd",
        ],
        cwd=ROOT,
        check=False,
        text=True,
        capture_output=True,
        env=env,
    )
    output = f"{proc.stdout}\n{proc.stderr}"
    assert proc.returncode == 0, output
