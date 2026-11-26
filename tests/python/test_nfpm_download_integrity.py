"""The Linux release must not package or sign an nfpm it did not pin.

The package-linux job downloads an nfpm archive and runs that binary to build
the deb that the next step signs and the release job uploads. These tests
serve that download URL themselves. They fail while a replaced archive is
still executed, packaged, signed, or uploaded, and they pass when the job
refuses that archive before those effects.

Other unchecksummed downloads in the same workflow (the games_module editor,
the chauffeur archive, and the Windows Inno Setup install) are not this
packager path and are not covered here.
"""

from __future__ import annotations

import hashlib
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import textwrap
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "cicd.yml"
ATTACKER = "NFPM_DOWNLOAD_INTEGRITY_ATTACKER"
DEB_NAME = "blazium-games_0.1.0_amd64.deb"
URL_RE = re.compile(r"https://github\.com/goreleaser/nfpm/releases/download/\S+")
DIGEST_RE = re.compile(r"\b[0-9a-fA-F]{64}\b")


def _run_blocks(text: str) -> list[str]:
    """Return literal `run: |` scripts with the same text Actions executes."""
    lines = text.splitlines()
    blocks: list[str] = []
    index = 0
    while index < len(lines):
        stripped = lines[index].lstrip()
        if not stripped.startswith("run: |"):
            index += 1
            continue
        indent = len(lines[index]) - len(stripped)
        index += 1
        body: list[str] = []
        while index < len(lines):
            line = lines[index]
            if line.strip() == "":
                body.append("")
                index += 1
                continue
            if len(line) - len(line.lstrip()) <= indent:
                break
            body.append(line)
            index += 1
        indents = [len(line) - len(line.lstrip()) for line in body if line.strip()]
        cut = min(indents) if indents else 0
        script = "\n".join(line[cut:] if line else "" for line in body)
        if script and not script.endswith("\n"):
            script += "\n"
        blocks.append(script)
    return blocks


def _run_script(needle: str) -> str:
    matches = [block for block in _run_blocks(WORKFLOW.read_text(encoding="utf-8")) if needle in block]
    assert len(matches) == 1, f"expected one step containing {needle!r}, found {len(matches)}"
    return matches[0]


def _nfpm_url(script: str) -> str | None:
    match = URL_RE.search(script)
    if match is None:
        return None
    return match.group(0)


def _recorded_digests(script: str, packaging: Path) -> set[str]:
    """Digests the packaging job can see without asking the release host."""
    found = set(DIGEST_RE.findall(script))
    if packaging.is_dir():
        for path in packaging.rglob("*"):
            if not path.is_file():
                continue
            rel = path.relative_to(packaging).as_posix()
            if rel not in script and path.name not in script:
                continue
            found.update(DIGEST_RE.findall(path.read_text(encoding="utf-8", errors="ignore")))
    return {item.lower() for item in found}


def _malicious_archive(marker: Path) -> bytes:
    script = "\n".join(
        [
            "#!/bin/sh",
            "set -eu",
            f"printf 'executed\\n' > {shlex.quote(str(marker))}",
            'target=""',
            'prev=""',
            'for arg in "$@"; do',
            '  if [ "$prev" = "--target" ]; then',
            "    target=$arg",
            "  fi",
            '  prev=$arg',
            "done",
            'if [ -z "$target" ]; then',
            '  echo "nfpm replacement was not given --target" >&2',
            "  exit 1",
            "fi",
            "work=$(mktemp -d)",
            'mkdir -p "$work/DEBIAN" "$work/opt/attacker"',
            'cat > "$work/DEBIAN/control" << \'EOF\'',
            "Package: blazium-games",
            "Version: 0.1.0",
            "Section: games",
            "Priority: optional",
            "Architecture: amd64",
            "Maintainer: Attacker <attacker@example.invalid>",
            "Description: attacker controlled package",
            "EOF",
            'cat > "$work/DEBIAN/postinst" << \'EOF\'',
            "#!/bin/sh",
            f"echo {ATTACKER}",
            "EOF",
            'chmod 755 "$work/DEBIAN/postinst"',
            f"printf '%s\\n' {shlex.quote(ATTACKER)} > \"$work/opt/attacker/payload\"",
            'dpkg-deb --root-owner-group --build "$work" "$target"',
            "",
        ]
    )
    import io
    import tarfile

    payload = script.encode("utf-8")
    info = tarfile.TarInfo(name="nfpm")
    info.size = len(payload)
    info.mode = 0o755
    info.mtime = 0
    blob = io.BytesIO()
    with tarfile.open(fileobj=blob, mode="w:gz") as archive:
        archive.addfile(info, io.BytesIO(payload))
    return blob.getvalue()


def _official_archive(url: str, cache: Path) -> bytes | None:
    if cache.is_file() and cache.stat().st_size > 1000:
        return cache.read_bytes()
    cache.parent.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run(
        ["curl", "-fsSL", "--retry", "2", "-o", str(cache), url],
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0 or not cache.is_file():
        return None
    return cache.read_bytes()


def _write_certs(directory: Path) -> None:
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-keyout",
            str(directory / "ca.key"),
            "-out",
            str(directory / "ca.pem"),
            "-days",
            "1",
            "-nodes",
            "-subj",
            "/CN=nfpm-integrity-test-ca",
        ],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        [
            "openssl",
            "req",
            "-newkey",
            "rsa:2048",
            "-keyout",
            str(directory / "srv.key"),
            "-out",
            str(directory / "srv.csr"),
            "-nodes",
            "-subj",
            "/CN=github.com",
        ],
        check=True,
        capture_output=True,
    )
    (directory / "san.cnf").write_text(
        "subjectAltName=DNS:github.com,DNS:release-assets.githubusercontent.com\n",
        encoding="utf-8",
    )
    subprocess.run(
        [
            "openssl",
            "x509",
            "-req",
            "-in",
            str(directory / "srv.csr"),
            "-CA",
            str(directory / "ca.pem"),
            "-CAkey",
            str(directory / "ca.key"),
            "-CAcreateserial",
            "-out",
            str(directory / "srv.pem"),
            "-days",
            "1",
            "-extfile",
            str(directory / "san.cnf"),
        ],
        check=True,
        capture_output=True,
    )


def _test_signing_key(home: Path) -> str:
    """Create a signing key for this process only. The value stays in the temp dir."""
    home.mkdir(mode=0o700, parents=True, exist_ok=True)
    subprocess.run(
        [
            "gpg",
            "--batch",
            "--pinentry-mode",
            "loopback",
            "--passphrase",
            "",
            "--quick-gen-key",
            "NFPM Integrity Test <nfpm-integrity@example.invalid>",
            "ed25519",
            "sign",
            "0",
        ],
        check=True,
        capture_output=True,
        env={**os.environ, "GNUPGHOME": str(home)},
    )
    exported = subprocess.run(
        ["gpg", "--batch", "--armor", "--export-secret-keys"],
        check=True,
        capture_output=True,
        env={**os.environ, "GNUPGHOME": str(home)},
    )
    return exported.stdout.decode("utf-8")


def _prepare_tree(workspace: Path) -> None:
    packaging = workspace / "packaging" / "linux"
    shutil.copytree(ROOT / "packaging" / "linux", packaging)
    export = workspace / "export"
    export.mkdir()
    for name in ("BlaziumLauncher", "chauffeur", "blazium-cli", "crash_reporter"):
        path = export / name
        path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        path.chmod(0o755)
    (export / "VERSION").write_text("0.1.0\n", encoding="utf-8")
    (workspace / "dist").mkdir()


def _server_source() -> str:
    return textwrap.dedent(
        '''\
        import hashlib
        import json
        import ssl
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from pathlib import Path
        from urllib.parse import urlsplit

        ws = Path(__import__("os").environ["HARNESS_WS"])
        bodies = [path.read_bytes() for path in sorted((ws / "bodies").glob("*.tar.gz"))]
        malicious = (ws / "malicious.tar.gz").read_bytes()
        malicious_digest = hashlib.sha256(malicious).hexdigest()
        index_path = ws / "body-index.txt"
        index_path.write_text("0", encoding="utf-8")
        log_path = ws / "requests.log"

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                host = (self.headers.get("Host") or "").split(":")[0]
                path = urlsplit(self.path).path
                probe = self.headers.get("X-Harness-Probe") == "1"
                with log_path.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps({"host": host, "path": path, "probe": probe}) + "\\n")
                if path.endswith("/checksums.txt"):
                    body = f"{malicious_digest}  nfpm_2.41.3_Linux_x86_64.tar.gz\\n".encode()
                    self._bytes(200, body, "text/plain")
                    return
                if path.endswith("nfpm_2.41.3_Linux_x86_64.tar.gz") and host == "github.com":
                    self.send_response(302)
                    self.send_header("Location", "https://release-assets.githubusercontent.com/nfpm-asset")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if host == "release-assets.githubusercontent.com":
                    if probe:
                        payload = malicious
                    else:
                        current = int(index_path.read_text(encoding="utf-8") or "0")
                        payload = bodies[min(current, len(bodies) - 1)]
                        index_path.write_text(str(current + 1), encoding="utf-8")
                    self._bytes(200, payload, "application/gzip")
                    return
                self._bytes(404, b"not found\\n", "text/plain")

            def _bytes(self, status, payload, content_type):
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(payload)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, fmt, *args):
                return

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(ws / "certs" / "srv.pem"), str(ws / "certs" / "srv.key"))
        server = ThreadingHTTPServer(("127.0.0.1", 443), Handler)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        server.serve_forever()
        '''
    )


def _run_job(workspace: Path, bodies: list[bytes], malicious: bytes, signing_key: str) -> dict:
    _prepare_tree(workspace)
    marker = workspace / "attacker-nfpm-ran"
    (workspace / "bodies").mkdir()
    for index, body in enumerate(bodies):
        (workspace / "bodies" / f"{index:02d}.tar.gz").write_bytes(body)
    (workspace / "malicious.tar.gz").write_bytes(malicious)
    certs = workspace / "certs"
    certs.mkdir()
    _write_certs(certs)
    hosts = workspace / "hosts"
    hosts.write_text(
        "127.0.0.1 github.com release-assets.githubusercontent.com\n"
        "::1 github.com release-assets.githubusercontent.com\n",
        encoding="utf-8",
    )
    (workspace / "server.py").write_text(_server_source(), encoding="utf-8")
    build_script = _run_script("nfpm package")
    sign_script = _run_script("gpg --detach-sign")
    release_script = _run_script("gh release create")
    url = _nfpm_url(build_script)
    (workspace / "build.sh").write_text(build_script, encoding="utf-8")
    (workspace / "sign.sh").write_text(sign_script, encoding="utf-8")
    (workspace / "release.sh").write_text(release_script, encoding="utf-8")
    key_path = workspace / "signing-key.asc"
    key_path.write_text(signing_key, encoding="utf-8")
    key_path.chmod(0o600)
    stub = workspace / "bin"
    stub.mkdir()
    (stub / "gh").write_text(
        "\n".join(
            [
                "#!/bin/sh",
                "printf '%s\\n' \"$@\" >> \"$GH_ARGS_LOG\"",
                "printf '\\n---\\n' >> \"$GH_ARGS_LOG\"",
                'if [ "$1" = "release" ] && [ "$2" = "view" ]; then',
                "  exit 1",
                "fi",
                "exit 0",
                "",
            ]
        ),
        encoding="utf-8",
    )
    (stub / "gh").chmod(0o755)
    harness = workspace / "harness.sh"
    harness.write_text(
        textwrap.dedent(
            f"""\
            #!/bin/bash
            set -eu
            ip link set lo up
            mount --bind {shlex.quote(str(hosts))} /etc/hosts
            export HARNESS_WS={shlex.quote(str(workspace))}
            python3 {shlex.quote(str(workspace / "server.py"))} >/tmp/nfpm-integrity-server.log 2>&1 &
            server_pid=$!
            trap 'kill "$server_pid" >/dev/null 2>&1 || true' EXIT
            rm -f /tmp/nfpm /tmp/nfpm.tar.gz
            ready=0
            for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
              if bash -c 'echo >/dev/tcp/127.0.0.1/443' >/dev/null 2>&1; then
                ready=1
                break
              fi
              sleep 0.1
            done
            test "$ready" = 1
            export SSL_CERT_FILE={shlex.quote(str(certs / "ca.pem"))}
            export HOME={shlex.quote(str(workspace / "home"))}
            mkdir -p "$HOME"
            url={shlex.quote(url or "")}
            if [ -n "$url" ]; then
              curl -fsSL -H "X-Harness-Probe: 1" -o {shlex.quote(str(workspace / "probe.tar.gz"))} "$url"
              cmp {shlex.quote(str(workspace / "probe.tar.gz"))} {shlex.quote(str(workspace / "malicious.tar.gz"))}
            fi
            export GITHUB_WORKSPACE={shlex.quote(str(workspace))}
            export VERSION=0.1.0
            export SOURCE_DIR={shlex.quote(str(workspace / "export"))}
            export NFPM_ARCH=amd64
            set +e
            ( cd "$GITHUB_WORKSPACE" && bash -e {shlex.quote(str(workspace / "build.sh"))} ) >{shlex.quote(str(workspace / "build.log"))} 2>&1
            build_exit=$?
            set -e
            printf '%s\\n' "$build_exit" > {shlex.quote(str(workspace / "build.exit"))}
            sign_exit=skipped
            if [ "$build_exit" -eq 0 ]; then
              export GNUPGHOME={shlex.quote(str(workspace / "sign-gnupg"))}
              mkdir -p "$GNUPGHOME"
              chmod 700 "$GNUPGHOME"
              export GPG_PRIVATE_KEY
              GPG_PRIVATE_KEY=$(cat {shlex.quote(str(key_path))})
              set +e
              ( cd "$GITHUB_WORKSPACE" && bash -e {shlex.quote(str(workspace / "sign.sh"))} ) >{shlex.quote(str(workspace / "sign.log"))} 2>&1
              sign_code=$?
              set -e
              sign_exit=$sign_code
              unset GPG_PRIVATE_KEY
            fi
            printf '%s\\n' "$sign_exit" > {shlex.quote(str(workspace / "sign.exit"))}
            release_exit=skipped
            if [ "$build_exit" -eq 0 ] && {{ [ "$sign_exit" = skipped ] || [ "$sign_exit" -eq 0 ]; }}; then
              export GITHUB_SHA=30de23635f6fcfd942cb38341b81bb19ac6ff1fb
              export GITHUB_REPOSITORY=blazium-games/games_launcher
              export GH_TOKEN=placeholder-not-a-secret
              export GH_ARGS_LOG={shlex.quote(str(workspace / "gh-args.log"))}
              : > "$GH_ARGS_LOG"
              export PATH={shlex.quote(str(workspace / "bin"))}:$PATH
              set +e
              ( cd "$GITHUB_WORKSPACE" && bash -e {shlex.quote(str(workspace / "release.sh"))} ) >{shlex.quote(str(workspace / "release.log"))} 2>&1
              release_code=$?
              set -e
              release_exit=$release_code
            fi
            printf '%s\\n' "$release_exit" > {shlex.quote(str(workspace / "release.exit"))}
            if [ -e /tmp/nfpm ]; then
              printf 'yes\\n' > {shlex.quote(str(workspace / "extracted-nfpm"))}
            else
              printf 'no\\n' > {shlex.quote(str(workspace / "extracted-nfpm"))}
            fi
            """
        ),
        encoding="utf-8",
    )
    harness.chmod(0o755)
    proc = subprocess.run(
        [
            "unshare",
            "--user",
            "--map-root-user",
            "--net",
            "--mount",
            "bash",
            str(harness),
        ],
        check=False,
        capture_output=True,
    )
    if proc.returncode != 0:
        detail = proc.stderr.decode("utf-8", errors="replace")[-4000:]
        server_log = workspace / "server-missing"
        log_path = Path("/tmp/nfpm-integrity-server.log")
        if log_path.is_file():
            server_log = log_path
        raise AssertionError(
            "integrity harness failed before the assertion "
            f"(exit {proc.returncode})\\n{detail}\\n"
            f"server={server_log.read_text(encoding='utf-8', errors='replace')[-2000:] if server_log.is_file() else ''}"
        )
    deb = workspace / "dist" / DEB_NAME
    signature = workspace / "dist" / f"{DEB_NAME}.asc"
    package_text = _package_text(deb)
    attacker_in_deb = ATTACKER in package_text
    uploaded = False
    gh_log = workspace / "gh-args.log"
    if gh_log.is_file() and attacker_in_deb and DEB_NAME in gh_log.read_text(encoding="utf-8"):
        uploaded = True
    signature_ok = False
    if signature.is_file() and deb.is_file() and attacker_in_deb:
        verify = subprocess.run(
            [
                "gpg",
                "--batch",
                "--verify",
                str(signature),
                str(deb),
            ],
            capture_output=True,
            env={**os.environ, "GNUPGHOME": str(workspace / "sign-gnupg")},
        )
        signature_ok = verify.returncode == 0
    build_log = (workspace / "build.log").read_text(encoding="utf-8", errors="replace")
    return {
        "build_exit": int((workspace / "build.exit").read_text(encoding="utf-8").strip()),
        "sign_exit": (workspace / "sign.exit").read_text(encoding="utf-8").strip(),
        "release_exit": (workspace / "release.exit").read_text(encoding="utf-8").strip(),
        "attacker_executed": marker.is_file(),
        "deb_exists": deb.is_file(),
        "attacker_in_deb": attacker_in_deb,
        "signature_exists": signature.is_file(),
        "signature_verifies_attacker_deb": signature_ok,
        "attacker_deb_uploaded": uploaded,
        "extracted_nfpm": (workspace / "extracted-nfpm").read_text(encoding="utf-8").strip() == "yes",
        "body_index": int((workspace / "body-index.txt").read_text(encoding="utf-8").strip() or "0"),
        "build_log": build_log[-4000:],
        "postinst": package_text,
    }


def _package_text(deb: Path) -> str:
    """Maintainer scripts and data files. Both are compressed inside the deb."""
    if not deb.is_file():
        return ""
    with tempfile.TemporaryDirectory(prefix="nfpm-deb-") as raw:
        extracted = Path(raw)
        proc = subprocess.run(
            ["dpkg-deb", "--raw-extract", str(deb), str(extracted)],
            capture_output=True,
            check=False,
        )
        if proc.returncode != 0:
            return ""
        parts: list[str] = []
        for path in extracted.rglob("*"):
            if path.is_file():
                parts.append(path.read_text(encoding="utf-8", errors="replace"))
        return "\n".join(parts)


def _assert_attacker_stopped(result: dict) -> None:
    assert result["attacker_executed"] is False, result["build_log"]
    assert result["attacker_in_deb"] is False, result["postinst"]
    assert result["signature_verifies_attacker_deb"] is False
    assert result["attacker_deb_uploaded"] is False
    assert ATTACKER not in result["postinst"]


def _assert_unpinned_archive_rejected(result: dict, first: bytes, recorded: set[str]) -> None:
    _assert_attacker_stopped(result)
    digest = hashlib.sha256(first).hexdigest()
    if result["body_index"] == 0:
        # The job never accepted a body from the release URL.
        return
    if digest not in recorded:
        assert result["build_exit"] != 0, result["build_log"]
        assert result["deb_exists"] is False
        assert result["signature_exists"] is False
        assert result["extracted_nfpm"] is False
        assert result["sign_exit"] == "skipped"
        assert result["release_exit"] == "skipped"
        return
    # The first body matched a recorded digest. A later body must not run.
    assert result["body_index"] == 1


def test_replaced_nfpm_archive_is_not_packaged_or_signed(tmp_path: Path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    malicious = _malicious_archive(workspace / "attacker-nfpm-ran")
    digest = hashlib.sha256(malicious).hexdigest()
    script = _run_script("nfpm package")
    recorded = _recorded_digests(script, ROOT / "packaging" / "linux")
    assert digest not in recorded
    result = _run_job(workspace, [malicious, malicious], malicious, _test_signing_key(tmp_path / "keygen"))
    _assert_unpinned_archive_rejected(result, malicious, recorded)


def test_nfpm_bytes_hashed_are_the_bytes_that_are_packaged(tmp_path: Path):
    """A second fetch of the same URL must not supply the program that runs.

    The first response matches a digest recorded in the packaging sources when
    one is recorded and the bytes are available. Every later response is a
    different archive. Executing that later archive still fails this test.
    """
    workspace = tmp_path / "workspace"
    workspace.mkdir()
    malicious = _malicious_archive(workspace / "attacker-nfpm-ran")
    script = _run_script("nfpm package")
    recorded = _recorded_digests(script, ROOT / "packaging" / "linux")
    url = _nfpm_url(script)
    first = malicious
    if url is not None:
        official = _official_archive(url, tmp_path / "official.tar.gz")
        if official is not None and hashlib.sha256(official).hexdigest() in recorded:
            first = official
    assert hashlib.sha256(malicious).hexdigest() not in recorded
    result = _run_job(
        workspace,
        [first, malicious],
        malicious,
        _test_signing_key(tmp_path / "keygen"),
    )
    _assert_unpinned_archive_rejected(result, first, recorded)
