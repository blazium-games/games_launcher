#!/usr/bin/env python3
"""Download latest crash_reporter from cdn.blazium.app/crash_reporter/crash_reporter.json."""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from catalog_integrity import IntegrityError, finalize_bytes, read_url, read_version_file, validate_entry

CRASH_REPORTER_JSON = "https://cdn.blazium.app/crash_reporter/crash_reporter.json"
MAX_ATTEMPTS = 6
RETRY_SLEEP_SEC = 5


def resolve_download(
    manifest: dict[str, Any], platform: str, arch: str
) -> tuple[str | None, dict[str, Any] | None, str | None]:
    """Return the download for manifest['latest'] only."""
    versions: dict[str, Any] = manifest.get("versions") or {}
    latest = (manifest.get("latest") or "").strip() or None
    if not latest:
        return None, None, latest
    entry = versions.get(latest) or {}
    for d in entry.get("downloads") or []:
        if (
            d.get("platform") == platform
            and d.get("arch") == arch
            and (d.get("download_url") or "").strip()
        ):
            return latest, d, latest
    return None, None, latest


def _load_manifest() -> dict[str, Any]:
    raw = read_url(f"{CRASH_REPORTER_JSON}?nocache={int(time.time())}", timeout=60)
    return json.loads(raw)


def version_sidecar_path(out: Path) -> Path:
    return out.with_name("crash_reporter.version")


def write_version_sidecar(out: Path, version: str) -> Path:
    path = version_sidecar_path(out)
    path.write_text(version.strip() + "\n", encoding="utf-8")
    print(f"Wrote {path} ({version.strip()})")
    return path


def stamp_project_sha256(path: Path, sha: str) -> None:
    text = path.read_text(encoding="utf-8")
    line = f'crash_reporter/reporter_sha256="{sha.lower()}"'
    new, n = re.subn(r'(?m)^crash_reporter/reporter_sha256="[^"]*"$', line, text, count=1)
    if n != 1:
        raise SystemExit(f"{path}: crash_reporter/reporter_sha256 not found or ambiguous ({n})")
    path.write_text(new, encoding="utf-8")
    print(f"Stamped {path} reporter_sha256={sha.lower()}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True, choices=("windows", "linux", "darwin"))
    parser.add_argument("--arch", default="x86_64")
    parser.add_argument("--out", default="", help="Destination file path (omit with --stamp-project to skip download)")
    parser.add_argument("--stamp-project", default="", help="Write catalog sha256 into project.godot")
    args = parser.parse_args()
    if not args.out and not args.stamp_project:
        parser.error("need --out and/or --stamp-project")

    version: str | None = None
    download: dict[str, Any] | None = None
    latest: str | None = None

    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            manifest = _load_manifest()
        except Exception as exc:  # noqa: BLE001 — CI script; log and retry
            print(
                f"attempt {attempt}/{MAX_ATTEMPTS}: failed to load crash_reporter.json: {exc}",
                file=sys.stderr,
            )
            if attempt < MAX_ATTEMPTS:
                time.sleep(RETRY_SLEEP_SEC)
            continue

        version, download, latest = resolve_download(manifest, args.platform, args.arch)
        if version and download:
            break
        print(
            f"attempt {attempt}/{MAX_ATTEMPTS}: no download for "
            f"{args.platform}/{args.arch} (latest={latest or '?'})",
            file=sys.stderr,
        )
        if attempt < MAX_ATTEMPTS:
            time.sleep(RETRY_SLEEP_SEC)

    if not version or not download:
        print(
            f"no download for {args.platform}/{args.arch} after {MAX_ATTEMPTS} attempts",
            file=sys.stderr,
        )
        return 1

    if latest and version != latest:
        print(
            f"refusing crash_reporter {version}; catalog latest is {latest}",
            file=sys.stderr,
        )
        return 1

    out = Path(args.out) if args.out else None
    floor = read_version_file(version_sidecar_path(out)) if out is not None else ""
    try:
        sha = validate_entry(download, version, floor)
    except IntegrityError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    if args.stamp_project:
        stamp_project_sha256(Path(args.stamp_project), sha)
        if out is None:
            return 0

    if out is None:
        print("need --out to download", file=sys.stderr)
        return 1
    out.parent.mkdir(parents=True, exist_ok=True)
    url = str(download["download_url"])
    print(f"Fetching crash_reporter {version}: {url} -> {out}")
    try:
        data = read_url(url, timeout=180)
        finalize_bytes(download, sha, data)
    except IntegrityError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    except Exception as exc:  # noqa: BLE001 — CI script; report and stop
        print(f"download failed: {exc}", file=sys.stderr)
        return 1
    if len(data) < 1_000_000:
        print(f"downloaded crash_reporter too small ({len(data)} bytes)", file=sys.stderr)
        return 1

    out.write_bytes(data)
    out.chmod(out.stat().st_mode | 0o111)
    write_version_sidecar(out, version)
    print(f"sha256 ok ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
