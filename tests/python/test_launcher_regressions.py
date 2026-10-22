"""Locks the launcher fixes that are visible from source and the workflow."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


def _text(path: str) -> str:
    return (ROOT / path).read_text(encoding="utf-8")


def test_fetch_scripts_do_not_fail_open_on_an_empty_hash():
    for name in ("ci/fetch_latest_cli.py", "ci/fetch_latest_crash_reporter.py"):
        text = _text(name)
        assert "if expected:" not in text
        assert "validate_entry" in text
        assert "finalize_bytes" in text


def test_cli_resolution_stays_inside_the_install_dir():
    text = _text("scripts/launcher_updates.gd")
    assert 'OS.get_environment("BLAZIUM")' not in text
    assert "/usr/bin/blazium-cli" not in text
    assert "/opt/blazium/bin/blazium-cli" not in text
    assert "return \"blazium-cli\"" not in text
    assert "resolve_cli_in" in text


def test_download_rejects_escape_and_stalls():
    text = _text("scripts/installs.gd")
    assert "download_stalled" in text
    assert 'begins_with("https://")' in text
    assert ".part" in text
    assert "install_basename" in text


def test_irc_commands_are_tokens_and_reconnect():
    text = _text("scripts/irc_client.gd")
    assert "parse_line" in text
    assert "note_disconnect" in text
    assert "target_ok" in text
    assert '" 903 "' not in text
    assert '" JOIN "' not in text


def test_listing_does_not_scan_shelves_for_the_owner():
    text = _text("scripts/session.gd")
    owner = text.split("func owner_name", 1)[1].split("\nfunc ", 1)[0]
    assert "get_shelf" not in owner
    assert "shelf(" not in owner
    assert "purchase_key" in text
    assert "card_top_up_cents" in text


def test_install_record_and_stable_default_are_present():
    text = _text("scripts/installs.gd")
    assert "installed.json" in text
    assert "The download has no checksum" in text
    assert '"dev"' in text and '"custom"' in text
    router = _text("scripts/uri_router.gd")
    assert "allowed_channel" in router
    assert "stable or beta" not in router


def test_workflow_does_not_hand_secrets_to_a_mutable_third_party_action():
    text = _text(".github/workflows/cicd.yml")
    assert "bioblaze/sslcom-code-signer@v" not in text
    assert "57740ed8de661c667ea10e29fca4b1dab12ad560" in text
    assert "secrets.DO_ACCESS_KEY" not in text
    assert "secrets.DO_SECRET_KEY" not in text
    assert "secrets.DO_SPACE_NAME" not in text
    assert "secrets.DO_SPACE_REGION" not in text
    top, jobs = text.split("jobs:", 1)
    assert "contents: write" not in top
    assert "contents: read" in top
    assert "environment: production" in jobs
    assert "github.event_name != 'pull_request'" in text
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped.startswith("uses:"):
            continue
        ref = stripped.split("uses:", 1)[1].strip().split("#", 1)[0].strip()
        if ref.startswith("actions/"):
            continue
        _name, sep, rev = ref.rpartition("@")
        assert sep == "@"
        assert len(rev) == 40
        assert all(ch in "0123456789abcdef" for ch in rev)


def test_release_write_permission_is_job_scoped():
    text = _text(".github/workflows/cicd.yml")
    release = text.split("  release:", 1)[1].split("\n  package-", 1)[0]
    # release is the last job; fall back to the tail if the split missed.
    if "contents: write" not in release:
        release = text.split("  release:", 1)[1]
    assert "contents: write" in release


def test_installer_script_pins_host_hash_floor_and_publisher():
    script = _text("packaging/windows/select_hub.ps1")
    iss = _text("packaging/windows/blazium-games.iss")
    assert "cdn.blazium.app" in script
    assert "Get-AuthenticodeSignature" in script
    assert 'Divine Games, inc.' in script
    assert "Test-Older" in script
    assert "select_hub.ps1" in iss
    assert "$d.download_url" not in iss
    assert 'DestDir: "{app}"' in iss


def _powershell() -> str | None:
    for name in ("powershell.exe", "pwsh"):
        found = shutil.which(name)
        if found:
            return found
    return None


def _run_hub(tmp_path: Path, manifest: dict, floor: str = "") -> subprocess.CompletedProcess[str]:
    shell = _powershell()
    if shell is None:
        pytest.skip("powershell is not installed")
    manifest_path = tmp_path / "hub.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    floor_path = tmp_path / "floor.txt"
    if floor:
        floor_path.write_text(floor, encoding="utf-8")
    return subprocess.run(
        [
            shell,
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(ROOT / "packaging" / "windows" / "select_hub.ps1"),
            "-ManifestPath",
            str(manifest_path),
            "-OutFile",
            str(tmp_path / "setup.exe"),
            "-VersionFile",
            str(tmp_path / "version.txt"),
            "-FloorFile",
            str(floor_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def _manifest(url: str, sha: str, version: str = "1.2.3") -> dict:
    return {
        "latest": version,
        "versions": {
            version: {
                "downloads": [
                    {
                        "platform": "windows",
                        "arch": "x86_64",
                        "download_url": url,
                        "sha256": sha,
                    }
                ]
            }
        },
    }


def test_hub_script_rejects_an_empty_hash(tmp_path: Path):
    proc = _run_hub(tmp_path, _manifest("https://cdn.blazium.app/hub/setup.exe", ""))
    assert proc.returncode != 0
    assert not (tmp_path / "setup.exe").exists()


def test_hub_script_rejects_an_off_host_url(tmp_path: Path):
    proc = _run_hub(tmp_path, _manifest("https://evil.example/setup.exe", "ab" * 32))
    assert proc.returncode != 0
    assert not (tmp_path / "setup.exe").exists()


def test_postrm_keeps_the_install_on_upgrade():
    text = _text("packaging/linux/postrm")
    assert 'case "${1:-}"' in text
    assert "remove|purge|0" in text
    assert "xdg-mime" not in text
    assert text.index("case") < text.index("rm -rf /opt/blazium/games")
    postinst = _text("packaging/linux/postinst")
    assert "xdg-mime" not in postinst
    assert "BlaziumLauncher --ensure-launcher-remote" not in postinst


def test_windows_installer_reports_hub_failure_and_broadcasts_path():
    text = _text("packaging/windows/blazium-games.iss")
    assert "ChangesEnvironment=yes" in text
    assert "ExecAsOriginalUser" in text
    assert "NotifyHubFailure" in text
    assert "SuppressibleMsgBox" in text
    assert "DownloadToFile" not in text
    assert "{commonappdata}\\blazium\\launcher_remote.json" in text
    remote = _text("scripts/launcher_remote.gd")
    assert "ProgramData" not in remote
    assert "/etc/blazium/launcher_remote.json" not in remote


def test_windows_export_redacts_private_engine_paths(tmp_path: Path):
    import importlib.util

    spec = importlib.util.spec_from_file_location(
        "redact_private_paths", ROOT / "ci" / "redact_private_paths.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    path = b"D:\\a\\games_module\\games_module\\engine\\modules\\obfuscation\\register.cpp"
    blob = path + b"\0" + "games_module".encode("utf-16le") + b"\0\0"
    updated = module.redact(blob)
    assert len(updated) == len(blob)
    assert b"games_module" not in updated
    assert b"obfuscation" not in updated
    assert "games_module".encode("utf-16le") not in updated
    assert b"register.cpp" in updated


def test_hub_script_rejects_a_downgrade(tmp_path: Path):
    proc = _run_hub(
        tmp_path,
        _manifest("https://cdn.blazium.app/hub/setup.exe", "ab" * 32, "1.0.0"),
        floor="2.0.0",
    )
    assert proc.returncode != 0
    assert not (tmp_path / "setup.exe").exists()
