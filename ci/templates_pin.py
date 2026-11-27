#!/usr/bin/env python3
"""Build, package, and publish the launcher only from the pinned games_module engine.

ci/templates.lock.json names the games_module release and the SHA-256 of every
editor and export template the export job may run:

    {"tag": "templates-...", "sha256": {"<asset filename>": "<lowercase hex>", ...}}

Each binary is read once. The digest is taken from those bytes, and those same
bytes are what gets written, executed, packaged, or published. A later read of
the same path is never trusted.

Subcommands:
  plan          print the pinned tag and the asset names to download
  export        verify the downloaded editor and template, run the export,
                and write <export dir>/engine-provenance.json
  check-export  refuse an export whose provenance does not match the lock
  record        write the provenance for packaged installers
  check-release refuse installers whose provenance does not match the lock
  pin           write the lock from assets a maintainer downloaded and vetted
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
LOCK_PATH = ROOT / "ci" / "templates.lock.json"
REFUSAL = "refusing unverified templates export"
PROVENANCE_NAME = "engine-provenance.json"

_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
_HEX = re.compile(r"^[0-9a-f]{64}$")
_O_BINARY = getattr(os, "O_BINARY", 0)
_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


class Refused(Exception):
    pass


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _read_once(path: Path) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | _O_BINARY | _O_NOFOLLOW)
    except OSError as exc:
        raise Refused(f"{path}: {exc.strerror or exc}") from exc
    with os.fdopen(fd, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            raise Refused(f"{path} is not a regular file")
        return handle.read()


def _write_new(path: Path, data: bytes, mode: int) -> None:
    """Create path from data with a fresh inode, replacing whatever was there."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.new")
    if os.path.lexists(tmp):
        os.unlink(tmp)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | _O_BINARY | _O_NOFOLLOW, mode)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            if hasattr(os, "fchmod"):
                os.fchmod(handle.fileno(), mode)
        os.replace(tmp, path)
    except BaseException:
        if os.path.lexists(tmp):
            os.unlink(tmp)
        raise


def _unlink(path: Path) -> None:
    if os.path.lexists(path):
        os.unlink(path)


def _write_stdout(lines: list[str]) -> None:
    sys.stdout.flush()
    sys.stdout.buffer.write("".join(f"{line}\n" for line in lines).encode())
    sys.stdout.buffer.flush()


def load_lock(path: Path = LOCK_PATH) -> dict[str, Any]:
    if not path.is_file():
        raise Refused(f"{path.relative_to(ROOT)} is missing; pin a vetted games_module release first")
    try:
        lock = json.loads(_read_once(path).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise Refused(f"{path.relative_to(ROOT)} is not valid JSON: {exc}") from exc
    if not isinstance(lock, dict):
        raise Refused("templates lock must be a JSON object")
    tag = lock.get("tag")
    hashes = lock.get("sha256")
    if not isinstance(tag, str) or not _NAME.match(tag):
        raise Refused("templates lock has no valid tag")
    if not isinstance(hashes, dict) or not hashes:
        raise Refused("templates lock has no sha256 entries")
    for name, digest in hashes.items():
        if not isinstance(name, str) or not _NAME.match(name):
            raise Refused(f"templates lock names an invalid asset: {name!r}")
        if not isinstance(digest, str) or not _HEX.match(digest):
            raise Refused(f"templates lock has an invalid sha256 for {name}")
    return {"tag": tag, "sha256": dict(hashes)}


def _template_names(lock: dict[str, Any], template: str, template_alt: str) -> list[str]:
    return [name for name in dict.fromkeys((template, template_alt)) if name and name in lock["sha256"]]


def _read_provenance(path: Path) -> dict[str, Any]:
    if not os.path.lexists(path):
        raise Refused(f"{path} is missing")
    try:
        doc = json.loads(_read_once(path).decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise Refused(f"{path} is not valid JSON: {exc}") from exc
    if not isinstance(doc, dict):
        raise Refused(f"{path} must be a JSON object")
    return doc


def _check_engine(lock: dict[str, Any], doc: dict[str, Any], editor: str, templates: list[str], where: Path) -> None:
    if doc.get("tag") != lock["tag"]:
        raise Refused(f"{where} names tag {doc.get('tag')!r}, the lock pins {lock['tag']!r}")
    if editor not in lock["sha256"] or doc.get("editor_sha256") != lock["sha256"][editor]:
        raise Refused(f"{where} was not built by the pinned {editor}")
    if not templates or doc.get("template_sha256") not in {lock["sha256"][name] for name in templates}:
        raise Refused(f"{where} was not built from a pinned export template")


def _check_export(lock: dict[str, Any], editor: str, template: str, template_alt: str, file: Path) -> tuple[dict[str, Any], bytes]:
    where = file.parent / PROVENANCE_NAME
    doc = _read_provenance(where)
    _check_engine(lock, doc, editor, _template_names(lock, template, template_alt), where)
    data = _read_once(file)
    if doc.get("output_sha256") != _sha(data):
        raise Refused(f"{file} does not match the output recorded in {where}")
    return doc, data


def cmd_plan(args: argparse.Namespace) -> int:
    lock = load_lock()
    templates = _template_names(lock, args.template, args.template_alt)
    if args.editor not in lock["sha256"] or not templates:
        return 0
    _write_stdout([lock["tag"], args.editor, *templates])
    return 0


def cmd_export(args: argparse.Namespace) -> int:
    lock = load_lock()
    host = Path(args.host_dir)
    expected = lock["sha256"].get(args.editor)
    if expected is None:
        raise Refused(f"the lock has no sha256 for {args.editor}")
    editor = _read_once(host / args.editor)
    if _sha(editor) != expected:
        raise Refused(f"{args.editor} from {lock['tag']} does not match the lock")

    template: bytes | None = None
    for name in _template_names(lock, args.template, args.template_alt):
        if not os.path.lexists(host / name):
            continue
        template = _read_once(host / name)
        if _sha(template) != lock["sha256"][name]:
            raise Refused(f"{name} from {lock['tag']} does not match the lock")
        break
    if template is None:
        raise Refused(f"{lock['tag']} has no pinned export template for {args.editor}")

    out = Path(args.out)
    provenance = out.parent / PROVENANCE_NAME
    _unlink(out)
    _unlink(provenance)
    _write_new(ROOT / "templates" / args.template, template, 0o755)
    editor_path = ROOT / ".ci" / "editor" / args.editor
    _write_new(editor_path, editor, 0o755)

    proc = subprocess.run(
        [str(editor_path), "--headless", "--path", ".", "--export-release", args.preset, str(out)],
        check=False,
    )
    if proc.returncode != 0:
        print(f"export failed with exit code {proc.returncode}", file=sys.stderr)
        return proc.returncode or 1

    output = _read_once(out)
    if args.platform == "windows":
        sys.path.insert(0, str(Path(__file__).resolve().parent))
        from redact_private_paths import redact

        redacted = redact(output)
        if redacted != output:
            output = redacted
            _write_new(out, output, 0o755)
            print(f"redacted private paths in {out}")
        else:
            print(f"no private games_module paths in {out}")

    doc = {
        "tag": lock["tag"],
        "editor_sha256": _sha(editor),
        "template_sha256": _sha(template),
        "output_sha256": _sha(output),
    }
    _write_new(provenance, (json.dumps(doc, indent=2) + "\n").encode(), 0o644)
    print(f"exported {out} with {lock['tag']}")
    return 0


def cmd_check_export(args: argparse.Namespace) -> int:
    lock = load_lock()
    file = Path(args.file)
    _doc, data = _check_export(lock, args.editor, args.template, args.template_alt, file)
    _write_new(file, data, 0o755)
    print(f"{file} was exported by the pinned {lock['tag']} engine")
    return 0


def cmd_record(args: argparse.Namespace) -> int:
    lock = load_lock()
    doc, _data = _check_export(lock, args.editor, args.template, args.template_alt, Path(args.file))
    files: dict[str, str] = {}
    for item in args.installers:
        path = Path(item)
        files[path.name] = _sha(_read_once(path))
    record = {
        "tag": doc["tag"],
        "editor_sha256": doc["editor_sha256"],
        "template_sha256": doc["template_sha256"],
        "files": files,
    }
    _write_new(Path(args.out), (json.dumps(record, indent=2) + "\n").encode(), 0o644)
    print(f"wrote {args.out} for {len(files)} installer(s)")
    return 0


def cmd_check_release(args: argparse.Namespace) -> int:
    lock = load_lock()
    dist = Path(args.dist)
    pinned = set(lock["sha256"].values())
    expected: dict[str, str] = {}
    provenance = sorted(p for p in dist.iterdir() if re.fullmatch(r"engine-provenance(-[A-Za-z0-9_]+)?\.json", p.name))
    if not provenance:
        raise Refused(f"{dist} has no engine provenance")
    for where in provenance:
        doc = _read_provenance(where)
        if doc.get("tag") != lock["tag"]:
            raise Refused(f"{where} names tag {doc.get('tag')!r}, the lock pins {lock['tag']!r}")
        if doc.get("editor_sha256") not in pinned or doc.get("template_sha256") not in pinned:
            raise Refused(f"{where} was not built by the pinned engine")
        files = doc.get("files")
        if not isinstance(files, dict) or not files:
            raise Refused(f"{where} lists no installers")
        for name, digest in files.items():
            if not isinstance(name, str) or not _NAME.match(name) or not isinstance(digest, str) or not _HEX.match(digest):
                raise Refused(f"{where} has an invalid entry for {name!r}")
            if expected.setdefault(name, digest) != digest:
                raise Refused(f"{name} has conflicting provenance")

    names = {p.name for p in provenance}
    for path in sorted(dist.iterdir()):
        if path.name in names:
            continue
        if path.name not in expected:
            raise Refused(f"{path} has no engine provenance")
    for name, digest in sorted(expected.items()):
        path = dist / name
        data = _read_once(path)
        if _sha(data) != digest:
            raise Refused(f"{path} does not match its engine provenance")
        _write_new(path, data, 0o644)
    print(f"{len(expected)} installer(s) were built by the pinned {lock['tag']} engine")
    return 0


def cmd_pin(args: argparse.Namespace) -> int:
    if not _NAME.match(args.tag):
        raise Refused(f"invalid tag {args.tag!r}")
    directory = Path(args.dir)
    hashes: dict[str, str] = {}
    for name in args.assets:
        if not _NAME.match(name):
            raise Refused(f"invalid asset name {name!r}")
        hashes[name] = _sha(_read_once(directory / name))
    LOCK_PATH.write_text(json.dumps({"tag": args.tag, "sha256": hashes}, indent=2) + "\n", encoding="utf-8")
    print(f"pinned {args.tag} in {LOCK_PATH.relative_to(ROOT)}")
    return 0


def _engine_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--editor", required=True)
    parser.add_argument("--template", required=True)
    parser.add_argument("--template-alt", default="")


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    plan = sub.add_parser("plan")
    _engine_args(plan)
    plan.set_defaults(func=cmd_plan)

    export = sub.add_parser("export")
    _engine_args(export)
    export.add_argument("--host-dir", required=True)
    export.add_argument("--platform", required=True)
    export.add_argument("--preset", required=True)
    export.add_argument("--out", required=True)
    export.set_defaults(func=cmd_export)

    check = sub.add_parser("check-export")
    _engine_args(check)
    check.add_argument("--file", required=True)
    check.set_defaults(func=cmd_check_export)

    record = sub.add_parser("record")
    _engine_args(record)
    record.add_argument("--file", required=True)
    record.add_argument("--out", required=True)
    record.add_argument("installers", nargs="+")
    record.set_defaults(func=cmd_record)

    release = sub.add_parser("check-release")
    release.add_argument("--dist", required=True)
    release.set_defaults(func=cmd_check_release)

    pin = sub.add_parser("pin")
    pin.add_argument("--tag", required=True)
    pin.add_argument("--dir", required=True)
    pin.add_argument("assets", nargs="+")
    pin.set_defaults(func=cmd_pin)

    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Refused as exc:
        print(f"{REFUSAL}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
