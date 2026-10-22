"""Fail-closed checks for catalog downloads.

The sha256 and the URL travel in the same manifest, so an empty hash, an
off-host URL, a downgrade, or an unsigned Windows binary is rejected.
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ALLOWED_HOST = "cdn.blazium.app"
PUBLISHER_SUBJECT = 'CN="Divine Games, inc."'


class IntegrityError(Exception):
    """A catalog download failed a check that must not be skipped."""


class _PinnedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        if not pinned_url(newurl):
            raise IntegrityError("redirect left the pinned host")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def pinned_url(url: str) -> bool:
    raw = (url or "").strip()
    if not raw or any(ch in raw for ch in ("\r", "\n", "\x00")):
        return False
    parsed = urllib.parse.urlparse(raw)
    if parsed.scheme != "https":
        return False
    if parsed.username or parsed.password:
        return False
    host = (parsed.hostname or "").rstrip(".").lower()
    if host != ALLOWED_HOST:
        return False
    if parsed.port not in (None, 443):
        return False
    return True


def _version_parts(text: str) -> tuple[int, ...] | None:
    raw = (text or "").strip()
    if raw[:1].lower() == "v" and len(raw) > 1 and raw[1].isdigit():
        raw = raw[1:]
    core = raw.split("-", 1)[0].split("+", 1)[0]
    if not core:
        return None
    parts: list[int] = []
    for piece in core.split("."):
        if not piece.isdigit():
            return None
        parts.append(int(piece))
    if not parts:
        return None
    return tuple(parts)


def version_cmp(left: str, right: str) -> int:
    a = _version_parts(left)
    b = _version_parts(right)
    if a is None or b is None:
        raise IntegrityError("version is not comparable")
    width = max(len(a), len(b))
    a = a + (0,) * (width - len(a))
    b = b + (0,) * (width - len(b))
    if a < b:
        return -1
    if a > b:
        return 1
    return 0


def _sha256_hex(value: str) -> str:
    text = (value or "").strip().lower()
    if text.startswith("sha256:"):
        text = text[7:].strip()
    if len(text) != 64 or any(ch not in "0123456789abcdef" for ch in text):
        return ""
    return text


def validate_entry(download: dict, version: str, floor: str = "") -> str:
    """Return the required sha256, or raise IntegrityError before any write."""
    if not isinstance(download, dict):
        raise IntegrityError("download entry is missing")
    if not pinned_url(str(download.get("download_url") or "")):
        raise IntegrityError("download_url is not on the pinned host")
    sha = _sha256_hex(str(download.get("sha256") or ""))
    if not sha:
        raise IntegrityError("sha256 is missing")
    if _version_parts(version) is None:
        raise IntegrityError("version is not comparable")
    if floor:
        if version_cmp(version, floor) < 0:
            raise IntegrityError("refusing a downgrade")
    return sha


def read_version_file(path: Path) -> str:
    if not path.is_file():
        return ""
    return path.read_text(encoding="utf-8").strip()


def read_url(url: str, timeout: int = 180) -> bytes:
    if not pinned_url(url):
        raise IntegrityError("download_url is not on the pinned host")
    opener = urllib.request.build_opener(_PinnedRedirect)
    req = urllib.request.Request(
        url,
        headers={"Cache-Control": "no-cache", "Pragma": "no-cache"},
    )
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.read()
    except IntegrityError:
        raise
    except urllib.error.URLError as exc:
        if isinstance(exc.reason, IntegrityError):
            raise exc.reason from exc
        raise


def pe_has_authenticode(data: bytes) -> bool:
    """True when the PE certificate table points at a non-empty blob."""
    if len(data) < 0x40 or not data.startswith(b"MZ"):
        return False
    e_lfanew = int.from_bytes(data[0x3C:0x40], "little")
    if e_lfanew <= 0 or e_lfanew + 24 > len(data):
        return False
    if data[e_lfanew : e_lfanew + 4] != b"PE\x00\x00":
        return False
    opt = e_lfanew + 24
    magic = int.from_bytes(data[opt : opt + 2], "little")
    if magic == 0x20B:
        number_at = opt + 108
        dirs_at = opt + 112
    elif magic == 0x10B:
        number_at = opt + 92
        dirs_at = opt + 96
    else:
        return False
    if number_at + 4 > len(data):
        return False
    count = int.from_bytes(data[number_at : number_at + 4], "little")
    if count <= 4:
        return False
    entry = dirs_at + 4 * 8
    if entry + 8 > len(data):
        return False
    offset = int.from_bytes(data[entry : entry + 4], "little")
    size = int.from_bytes(data[entry + 4 : entry + 8], "little")
    if offset <= 0 or size <= 0:
        return False
    return offset + size <= len(data)


def authenticode_publisher_ok(data: bytes) -> bool:
    """Windows-only publisher check. Other platforms use the certificate table."""
    if os.name != "nt":
        return pe_has_authenticode(data)
    handle = tempfile.NamedTemporaryFile(prefix="blazium-sign-", suffix=".exe", delete=False)
    path = handle.name
    try:
        handle.write(data)
        handle.close()
        script = (
            "$ErrorActionPreference = 'Stop'; "
            "$sig = Get-AuthenticodeSignature -LiteralPath $env:BLAZIUM_CHECK_FILE; "
            "if ($sig.Status -ne 'Valid') { exit 1 }; "
            "$subject = ''; "
            "if ($sig.SignerCertificate) { $subject = [string]$sig.SignerCertificate.Subject }; "
            "if ($subject -notlike '*"
            + PUBLISHER_SUBJECT
            + "*') { exit 1 }; "
            "exit 0"
        )
        env = os.environ.copy()
        env["BLAZIUM_CHECK_FILE"] = path
        proc = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        return proc.returncode == 0
    finally:
        try:
            os.unlink(path)
        except OSError:
            pass


def finalize_bytes(download: dict, sha: str, data: bytes) -> None:
    got = hashlib.sha256(data).hexdigest()
    if got != _sha256_hex(sha):
        raise IntegrityError("sha256 mismatch")
    if data.startswith(b"MZ"):
        if not pe_has_authenticode(data):
            raise IntegrityError("Authenticode certificate is missing")
        if os.name == "nt" and not authenticode_publisher_ok(data):
            raise IntegrityError("Authenticode publisher is not trusted")
        return
    if data.startswith(b"\x7fELF"):
        if not pinned_url(str(download.get("sig_url") or "")):
            raise IntegrityError("detached signature is missing or not on the pinned host")
        return
    raise IntegrityError("download is not a signed PE or ELF")
