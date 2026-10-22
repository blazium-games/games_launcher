#!/usr/bin/env python3
"""Download latest blazium-cli from cdn.blazium.app/cli/cli.json."""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from catalog_integrity import IntegrityError, finalize_bytes, read_url, read_version_file, validate_entry

CLI_JSON = "https://cdn.blazium.app/cli/cli.json"
MAX_ATTEMPTS = 6
RETRY_SLEEP_SEC = 5


def resolve_download(
    manifest: dict[str, Any], platform: str, arch: str
) -> tuple[str | None, dict[str, Any] | None, str | None]:
    """Return the download for manifest['latest'] only.

    Older catalog versions are not a substitute when latest lacks this arch.
    """
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
    # Cloudflare edge can serve stale cli.json for up to max-age; bust cache.
    raw = read_url(f"{CLI_JSON}?nocache={int(time.time())}", timeout=60)
    return json.loads(raw)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--platform", required=True, choices=("windows", "linux", "darwin"))
    parser.add_argument("--arch", default="x86_64")
    parser.add_argument("--out", required=True, help="Destination file path")
    args = parser.parse_args()

    version: str | None = None
    download: dict[str, Any] | None = None
    latest: str | None = None

    for attempt in range(1, MAX_ATTEMPTS + 1):
        try:
            manifest = _load_manifest()
        except Exception as exc:  # noqa: BLE001 — CI script; log and retry
            print(
                f"attempt {attempt}/{MAX_ATTEMPTS}: failed to load cli.json: {exc}",
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
            f"refusing CLI {version}; catalog latest is {latest}",
            file=sys.stderr,
        )
        return 1

    out = Path(args.out)
    floor = read_version_file(out.with_name(out.name + ".version"))
    try:
        sha = validate_entry(download, version, floor)
    except IntegrityError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    out.parent.mkdir(parents=True, exist_ok=True)
    url = str(download["download_url"])
    print(f"Fetching CLI {version}: {url} -> {out}")
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
        print(f"downloaded CLI too small ({len(data)} bytes)", file=sys.stderr)
        return 1

    out.write_bytes(data)
    out.chmod(out.stat().st_mode | 0o111)
    out.with_name(out.name + ".version").write_text(version.strip() + "\n", encoding="utf-8")
    print(f"sha256 ok ({len(data)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
