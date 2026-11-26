"""Linux catalog tools must be rejected unless a detached signature matches.

The release workflow downloads blazium-cli and the crash reporter from
cdn.blazium.app and packages whatever those scripts write. The catalog
carries sha256 and sig_url in the same object, and the signature published
for a Linux build is a binary OpenPGP detached signature (gpg --detach-sign).

These tests fail while a pinned sig_url is treated as proof. They pass when
the bytes that are about to be written verify under catalog_integrity.PINNED_LINUX_PUBKEY
and under no other key. That value is assigned below; it is not read from the
manifest and it is not served by the catalog. A key downloaded from
cdn.blazium.app, including one named in the manifest, is the attacker's key.

linux/x86_32 uses the same two scripts and the same finalize_bytes check. The
launcher workflow invokes linux/x86_64 only, which is what these tests run.
"""

from __future__ import annotations

import builtins
import hashlib
import json
import os
import socket
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "ci"))

import catalog_integrity  # noqa: E402
import fetch_latest_cli  # noqa: E402
import fetch_latest_crash_reporter  # noqa: E402
from catalog_integrity import IntegrityError, finalize_bytes  # noqa: E402

VERSION = "9.9.9"
HOST = "https://cdn.blazium.app"
ELF_SIZE = 1_000_000


class _Key:
    def __init__(self, home: Path, uid: str):
        self.home = home
        self.home.chmod(0o700)
        env = os.environ.copy()
        env["GNUPGHOME"] = str(home)
        self.env = env
        subprocess.run(
            [
                "gpg",
                "--batch",
                "--pinentry-mode",
                "loopback",
                "--passphrase",
                "",
                "--quick-gen-key",
                uid,
                "ed25519",
                "sign",
                "never",
            ],
            check=True,
            capture_output=True,
            env=env,
        )
        exported = subprocess.run(
            ["gpg", "--batch", "--export", "--armor"],
            check=True,
            capture_output=True,
            env=env,
        )
        self.armored = exported.stdout.decode("ascii")

    def sign(self, data: bytes) -> bytes:
        handle = tempfile.NamedTemporaryFile(dir=self.home, delete=False)
        path = Path(handle.name)
        handle.close()
        sig_path = path.with_name(path.name + ".sig")
        try:
            path.write_bytes(data)
            subprocess.run(
                [
                    "gpg",
                    "--batch",
                    "--yes",
                    "--pinentry-mode",
                    "loopback",
                    "--passphrase",
                    "",
                    "--output",
                    str(sig_path),
                    "--detach-sign",
                    str(path),
                ],
                check=True,
                capture_output=True,
                env=self.env,
            )
            return sig_path.read_bytes()
        finally:
            path.unlink(missing_ok=True)
            sig_path.unlink(missing_ok=True)

    def verify(self, data: bytes, signature: bytes) -> int:
        """Confirm this fixture's signature is a real detached signature."""
        home = self.home / "verify"
        home.mkdir(mode=0o700, exist_ok=True)
        env = os.environ.copy()
        env["GNUPGHOME"] = str(home)
        pub = home / "pub.asc"
        pub.write_text(self.armored, encoding="ascii")
        subprocess.run(
            ["gpg", "--batch", "--import", str(pub)],
            check=True,
            capture_output=True,
            env=env,
        )
        blob = home / "blob"
        sig = home / "blob.sig"
        blob.write_bytes(data)
        sig.write_bytes(signature)
        proc = subprocess.run(
            ["gpg", "--batch", "--verify", str(sig), str(blob)],
            capture_output=True,
            env=env,
        )
        return proc.returncode


class _Body:
    def __init__(self, data: bytes):
        self._data = data
        self._off = 0

    def read(self, amt=-1):
        if amt is None or amt < 0:
            amt = len(self._data) - self._off
        chunk = self._data[self._off : self._off + amt]
        self._off += len(chunk)
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def close(self):
        return None


class Catalog:
    def __init__(self):
        self._bodies: dict[str, list[bytes]] = {}
        self.events: list[tuple[str, str]] = []

    def add(self, url: str, body: bytes, repeats: int = 1) -> None:
        path = urllib.parse.urlparse(url).path
        self._bodies.setdefault(path, [])
        self._bodies[path].extend([body] * repeats)

    def install(self, monkeypatch, created: list[str]) -> None:
        catalog = self

        def open_catalog(self, fullurl, data=None, timeout=socket._GLOBAL_DEFAULT_TIMEOUT):  # noqa: ANN001
            url = fullurl.full_url if isinstance(fullurl, urllib.request.Request) else fullurl
            path = urllib.parse.urlparse(url).path
            catalog.events.append(("fetch", path))
            queued = catalog._bodies.get(path)
            if not queued:
                raise urllib.error.URLError(path)
            body = queued.pop(0) if len(queued) > 1 else queued[0]
            return _Body(body)

        watched = {"blazium-cli", "crash_reporter", "blazium-cli.version", "crash_reporter.version"}
        real_builtin_open = builtins.open

        def note(path) -> None:
            text = os.fspath(path)
            if os.path.basename(text) not in watched:
                return
            created.append(text)
            catalog.events.append(("create", text))

        def tracing_open(file, mode="r", *args, **kwargs):
            if not isinstance(file, int) and any(flag in mode for flag in ("w", "a", "x")):
                note(file)
            return real_builtin_open(file, mode, *args, **kwargs)

        real_write_bytes = Path.write_bytes
        real_write_text = Path.write_text

        def tracing_write_bytes(self, data):
            note(self)
            return real_write_bytes(self, data)

        def tracing_write_text(self, data, encoding=None, errors=None, newline=None):
            note(self)
            return real_write_text(self, data, encoding=encoding, errors=errors, newline=newline)

        real_os_open = os.open

        def tracing_os_open(path, flags, mode=0o777, *, dir_fd=None):
            if not isinstance(path, int) and flags & os.O_CREAT:
                note(path)
            if dir_fd is None:
                return real_os_open(path, flags, mode)
            return real_os_open(path, flags, mode, dir_fd=dir_fd)

        def blocked(*args, **kwargs):
            raise OSError("outbound network is blocked")

        monkeypatch.setattr(urllib.request.OpenerDirector, "open", open_catalog)
        monkeypatch.setattr(socket, "create_connection", blocked)
        monkeypatch.setattr(builtins, "open", tracing_open)
        monkeypatch.setattr(os, "open", tracing_os_open)
        monkeypatch.setattr(Path, "write_bytes", tracing_write_bytes)
        monkeypatch.setattr(Path, "write_text", tracing_write_text)

    def fetched(self, url: str) -> list[int]:
        path = urllib.parse.urlparse(url).path
        return [i for i, event in enumerate(self.events) if event == ("fetch", path)]


def _elf(tag: bytes) -> bytes:
    body = b"\x7fELF" + tag
    if len(body) > ELF_SIZE:
        raise RuntimeError("tag does not fit in the ELF fixture")
    return body + bytes(ELF_SIZE - len(body))


def _manifest(download_url: str, sha: str, sig_url: str, filename: str, attacker_key: str) -> bytes:
    key_url = HOST + "/cli/attacker-key.asc"
    doc = {
        "latest": VERSION,
        "versions": {
            VERSION: {
                "downloads": [
                    {
                        "platform": "linux",
                        "arch": "x86_64",
                        "filename": filename,
                        "download_url": download_url,
                        "sig_url": sig_url,
                        "sha256": sha,
                        "size": ELF_SIZE,
                        "signing": "gpg",
                        "public_key": attacker_key,
                        "signing_key_url": key_url,
                    }
                ]
            }
        },
    }
    return json.dumps(doc).encode("utf-8")


@pytest.fixture(scope="module")
def keys(tmp_path_factory):
    trusted = _Key(tmp_path_factory.mktemp("trusted-gpg"), "Pinned <pinned@example.com>")
    attacker = _Key(tmp_path_factory.mktemp("attacker-gpg"), "Other <other@example.com>")
    sample = _elf(b"fixture")
    signature = trusted.sign(sample)
    if trusted.verify(sample, signature) != 0:
        raise RuntimeError("fixture could not verify its own detached signature")
    return trusted, attacker


def _tool(module):
    if module is fetch_latest_cli:
        filename = "blazium-cli"
        manifest_url = HOST + "/cli/cli.json"
        binary_url = HOST + f"/cli/linux/x86_64/{VERSION}/{filename}"
    else:
        filename = "crash_reporter"
        manifest_url = HOST + "/crash_reporter/crash_reporter.json"
        binary_url = HOST + f"/crash_reporter/linux/x86_64/{VERSION}/{filename}"
    return filename, manifest_url, binary_url, binary_url + ".sig"


def _prepare(monkeypatch, keys, module, elf: bytes, signature: bytes, binary_sequence: list[bytes] | None = None):
    trusted, attacker = keys
    monkeypatch.setattr(catalog_integrity, "PINNED_LINUX_PUBKEY", trusted.armored, raising=False)
    filename, manifest_url, binary_url, sig_url = _tool(module)
    sha = hashlib.sha256(elf).hexdigest()
    catalog = Catalog()
    catalog.add(manifest_url, _manifest(binary_url, sha, sig_url, filename, attacker.armored), repeats=4)
    if binary_sequence is None:
        catalog.add(binary_url, elf, repeats=4)
    else:
        catalog.add(binary_url, binary_sequence[0], repeats=1)
        for extra in binary_sequence[1:]:
            catalog.add(binary_url, extra, repeats=1)
        catalog.add(binary_url, binary_sequence[-1], repeats=4)
    catalog.add(sig_url, signature, repeats=4)
    attacker_key = attacker.armored.encode("ascii")
    for url in (
        HOST + "/cli/attacker-key.asc",
        HOST + "/cli/pubkey.asc",
        HOST + "/cli/linux/pubkey.asc",
        HOST + f"/cli/linux/x86_64/{VERSION}/{filename}.asc",
        HOST + "/crash_reporter/pubkey.asc",
        HOST + "/crash_reporter/linux/pubkey.asc",
        HOST + "/keys/linux.asc",
    ):
        catalog.add(url, attacker_key, repeats=4)
    created: list[str] = []
    catalog.install(monkeypatch, created)
    module.MAX_ATTEMPTS = 1
    module.RETRY_SLEEP_SEC = 0
    return catalog, created, sig_url


def _run(module, out: Path) -> int:
    argv = [module.__file__, "--platform", "linux", "--arch", "x86_64", "--out", str(out)]
    old = sys.argv
    sys.argv = argv
    try:
        return module.main()
    finally:
        sys.argv = old


@pytest.mark.parametrize("module", [fetch_latest_cli, fetch_latest_crash_reporter], ids=["cli", "crash_reporter"])
def test_other_key_does_not_install_the_elf(tmp_path, monkeypatch, keys, module):
    trusted, attacker = keys
    elf = _elf(b"other-key")
    signature = attacker.sign(elf)
    assert attacker.verify(elf, signature) == 0
    assert trusted.verify(elf, signature) != 0
    catalog, created, _sig_url = _prepare(monkeypatch, keys, module, elf, signature)
    out = tmp_path / _tool(module)[0]
    code = _run(module, out)
    assert not created and not out.exists(), (
        f"wrote the ELF signed by a key other than PINNED_LINUX_PUBKEY (exit {code}, created {created})"
    )
    assert code != 0


@pytest.mark.parametrize("module", [fetch_latest_cli, fetch_latest_crash_reporter], ids=["cli", "crash_reporter"])
def test_signature_of_a_different_elf_does_not_install(tmp_path, monkeypatch, keys, module):
    trusted, _attacker = keys
    delivered = _elf(b"delivered")
    covered = _elf(b"covered")
    signature = trusted.sign(covered)
    assert trusted.verify(covered, signature) == 0
    assert trusted.verify(delivered, signature) != 0
    # First response is the catalogued ELF. A later response is the ELF the
    # signature covers. Verification has to bind the bytes that will be written.
    catalog, created, _sig_url = _prepare(
        monkeypatch,
        keys,
        module,
        delivered,
        signature,
        binary_sequence=[delivered, covered],
    )
    out = tmp_path / _tool(module)[0]
    code = _run(module, out)
    assert not created and not out.exists(), (
        f"wrote an ELF the pinned signature does not cover (exit {code}, created {created}, events {catalog.events})"
    )
    assert code != 0


@pytest.mark.parametrize("module", [fetch_latest_cli, fetch_latest_crash_reporter], ids=["cli", "crash_reporter"])
def test_pinned_signature_of_the_written_bytes_is_installed(tmp_path, monkeypatch, keys, module):
    trusted, _attacker = keys
    elf = _elf(b"pinned-ok")
    signature = trusted.sign(elf)
    assert trusted.verify(elf, signature) == 0
    catalog, created, sig_url = _prepare(monkeypatch, keys, module, elf, signature)
    out = tmp_path / _tool(module)[0]
    code = _run(module, out)
    sig_at = catalog.fetched(sig_url)
    assert sig_at, "detached signature was not downloaded from sig_url"
    assert code == 0
    assert out.read_bytes() == elf
    created_at = [i for i, event in enumerate(catalog.events) if event[0] == "create" and event[1] == str(out)]
    assert created_at and sig_at[0] < created_at[0]
    assert created


def test_finalize_bytes_rejects_a_signature_from_another_key(monkeypatch, keys):
    trusted, attacker = keys
    elf = _elf(b"direct-other")
    signature = attacker.sign(elf)
    filename, _manifest_url, binary_url, sig_url = _tool(fetch_latest_cli)
    catalog, _created, _sig = _prepare(monkeypatch, keys, fetch_latest_cli, elf, signature)
    download = {
        "download_url": binary_url,
        "sig_url": sig_url,
        "sha256": hashlib.sha256(elf).hexdigest(),
        "signing": "gpg",
        "public_key": attacker.armored,
        "filename": filename,
    }
    with pytest.raises(IntegrityError):
        finalize_bytes(download, download["sha256"], elf)
    assert catalog.fetched(sig_url), "finalize_bytes accepted the ELF without reading sig_url"


def test_finalize_bytes_rejects_when_a_later_download_is_the_signed_one(monkeypatch, keys):
    trusted, _attacker = keys
    delivered = _elf(b"direct-delivered")
    covered = _elf(b"direct-covered")
    signature = trusted.sign(covered)
    _filename, _manifest_url, binary_url, sig_url = _tool(fetch_latest_cli)
    catalog, created, _sig = _prepare(
        monkeypatch,
        keys,
        fetch_latest_cli,
        delivered,
        signature,
        binary_sequence=[delivered, covered],
    )
    download = {
        "download_url": binary_url,
        "sig_url": sig_url,
        "sha256": hashlib.sha256(delivered).hexdigest(),
        "signing": "gpg",
    }
    with pytest.raises(IntegrityError):
        finalize_bytes(download, download["sha256"], delivered)
    assert not created
    assert catalog.fetched(sig_url)


def test_finalize_bytes_accepts_the_bytes_the_pinned_key_signed(monkeypatch, keys):
    trusted, _attacker = keys
    elf = _elf(b"direct-ok")
    signature = trusted.sign(elf)
    filename, _manifest_url, binary_url, sig_url = _tool(fetch_latest_cli)
    catalog, created, _sig = _prepare(monkeypatch, keys, fetch_latest_cli, elf, signature)
    download = {
        "download_url": binary_url,
        "sig_url": sig_url,
        "sha256": hashlib.sha256(elf).hexdigest(),
        "signing": "gpg",
        "filename": filename,
    }
    finalize_bytes(download, download["sha256"], elf)
    assert catalog.fetched(sig_url), "detached signature was not downloaded from sig_url"
    assert not created
