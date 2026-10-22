"""Regression tests for catalog downloads. These fail if the fail-open checks return."""

from __future__ import annotations

import hashlib
import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ci"))

from catalog_integrity import (  # noqa: E402
    IntegrityError,
    finalize_bytes,
    pe_has_authenticode,
    pinned_url,
    validate_entry,
    version_cmp,
)
from fetch_latest_cli import resolve_download  # noqa: E402


SHA = "ab" * 32
URL = "https://cdn.blazium.app/cli/windows/x86_64/1.2.3/blazium-cli.exe"


def _entry(**overrides):
    download = {
        "download_url": URL,
        "sha256": SHA,
        "sig_url": "https://cdn.blazium.app/cli/linux/x86_64/1.2.3/blazium-cli.sig",
    }
    download.update(overrides)
    return download


def test_empty_sha256_is_rejected():
    with pytest.raises(IntegrityError, match="sha256"):
        validate_entry(_entry(sha256=""), "1.2.3")


def test_whitespace_sha256_is_rejected():
    with pytest.raises(IntegrityError, match="sha256"):
        validate_entry(_entry(sha256="   "), "1.2.3")


def test_off_host_download_is_rejected():
    with pytest.raises(IntegrityError, match="pinned host"):
        validate_entry(_entry(download_url="https://evil.example/blazium-cli.exe"), "1.2.3")


def test_http_and_userinfo_are_rejected():
    assert not pinned_url("http://cdn.blazium.app/cli/blazium-cli.exe")
    assert not pinned_url("https://user:pass@cdn.blazium.app/cli/blazium-cli.exe")
    assert pinned_url(URL)


def test_downgrade_is_rejected_and_equal_is_allowed():
    with pytest.raises(IntegrityError, match="downgrade"):
        validate_entry(_entry(), "1.0.0", "1.2.0")
    assert validate_entry(_entry(), "1.2.0", "1.2.0") == SHA
    assert validate_entry(_entry(), "1.10.0", "1.9.0") == SHA
    assert version_cmp("1.10.0", "1.9.0") == 1


def test_uncomparable_version_is_rejected():
    with pytest.raises(IntegrityError, match="comparable"):
        validate_entry(_entry(), "latest")


def test_resolve_download_does_not_fall_back_to_an_older_build():
    manifest = {
        "latest": "2.0.0",
        "versions": {
            "1.0.0": {
                "downloads": [
                    {"platform": "linux", "arch": "x86_64", "download_url": "https://cdn.blazium.app/old"}
                ]
            },
            "2.0.0": {"downloads": []},
        },
    }
    version, download, latest = resolve_download(manifest, "linux", "x86_64")
    assert version is None
    assert download is None
    assert latest == "2.0.0"


def _pe(with_cert: bool) -> bytes:
    blob = bytearray(0x200)
    e_lfanew = 0x80
    blob[0:2] = b"MZ"
    blob[0x3C:0x40] = e_lfanew.to_bytes(4, "little")
    blob[e_lfanew : e_lfanew + 4] = b"PE\x00\x00"
    coff = e_lfanew + 4
    blob[coff : coff + 2] = (0x8664).to_bytes(2, "little")
    blob[coff + 16 : coff + 18] = (240).to_bytes(2, "little")
    opt = coff + 20
    blob[opt : opt + 2] = (0x20B).to_bytes(2, "little")
    blob[opt + 108 : opt + 112] = (16).to_bytes(4, "little")
    if with_cert:
        cert_off = 0x180
        blob[opt + 144 : opt + 148] = cert_off.to_bytes(4, "little")
        blob[opt + 148 : opt + 152] = (16).to_bytes(4, "little")
        blob[cert_off : cert_off + 16] = b"\x00" * 16
    return bytes(blob)


def test_unsigned_pe_is_rejected():
    data = _pe(False)
    assert not pe_has_authenticode(data)
    download = _entry(sha256=hashlib.sha256(data).hexdigest())
    with pytest.raises(IntegrityError, match="Authenticode"):
        finalize_bytes(download, download["sha256"], data)


def test_certificate_table_without_publisher_is_rejected_on_windows():
    data = _pe(True)
    assert pe_has_authenticode(data)
    download = _entry(sha256=hashlib.sha256(data).hexdigest())
    if os.name == "nt":
        with pytest.raises(IntegrityError, match="publisher"):
            finalize_bytes(download, download["sha256"], data)
    else:
        finalize_bytes(download, download["sha256"], data)


def test_elf_without_a_pinned_signature_is_rejected():
    data = b"\x7fELF" + b"\x00" * 32
    download = _entry(sha256=hashlib.sha256(data).hexdigest(), sig_url="")
    with pytest.raises(IntegrityError, match="signature"):
        finalize_bytes(download, download["sha256"], data)
    download["sig_url"] = "https://evil.example/blazium-cli.sig"
    with pytest.raises(IntegrityError, match="signature"):
        finalize_bytes(download, download["sha256"], data)


def test_elf_with_a_pinned_signature_url_is_accepted():
    data = b"\x7fELF" + b"\x00" * 32
    digest = hashlib.sha256(data).hexdigest()
    finalize_bytes(_entry(sha256=digest), digest, data)


def test_hash_mismatch_is_rejected():
    data = b"\x7fELF" + b"\x00" * 32
    with pytest.raises(IntegrityError, match="mismatch"):
        finalize_bytes(_entry(), SHA, data)
