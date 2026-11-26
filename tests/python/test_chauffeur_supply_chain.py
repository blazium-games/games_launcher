"""Spec for the chauffeur binary the release workflow ships.

The Download chauffeur step in .github/workflows/cicd.yml must treat the
archive as untrusted input:

- Read packaging/chauffeur/pins.json (relative to the repo root). Each of
  windows-amd64 and linux-amd64 has version, url, and sha256.
- version is an exact version, never "latest". url is that exact object,
  https://cdn.blazium.online/tools/chauffeur/<platform>/<version>/archive/default,
  and sha256 is the lowercase hex SHA-256 of the archive bytes.
- Download that url once. Hash those bytes. Mismatch exits non-zero before
  the archive is opened as a zip and before anything is copied to export/.
- A second response from the same url is not the bytes that are unpacked.
- On success the zip member <chauffeur_name> is copied to export/<chauffeur_name>.
  The Windows installer then copies export/chauffeur.exe to {autopf}\\Blazium
  and EnvAddPath adds that directory to the system PATH. The Linux package
  installs the binary at /opt/blazium/bin/chauffeur and /usr/bin/chauffeur
  (packaging/linux/games.sh) execs it.

These tests fail while the workflow still curls the floating latest object
and packages it. A fix that hashes one download and then fetches the url
again before unzip still fails.

Left untested: ci/fetch_latest_cli.py and ci/fetch_latest_crash_reporter.py
already reject a missing hash. packaging/windows/select_hub.ps1 does too.
The nfpm tarball download and the games_module template download are not
the chauffeur binary this package puts on PATH.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

import pytest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "cicd.yml"
PINS = ROOT / "packaging" / "chauffeur" / "pins.json"
VERSION = "9.9.9"
FIXTURE_PORT = 8765
GOOD = b"#!/bin/sh\necho CHAUFFEUR_PINNED_BYTES\n"
BAD = b"#!/bin/sh\necho CHAUFFEUR_SUBSTITUTED_PAYLOAD\n"


def _workflow() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def _matrix() -> list[tuple[str, str]]:
    pairs = re.findall(
        r"chauffeur_platform:\s+(\S+)\n\s+chauffeur_name:\s+(\S+)",
        _workflow(),
    )
    if not pairs:
        raise AssertionError("cicd.yml has no chauffeur matrix entries")
    return pairs


def _run_block(step_name: str) -> str:
    text = _workflow()
    marker = f"- name: {step_name}\n"
    start = text.find(marker)
    if start < 0:
        raise AssertionError(f"workflow has no step {step_name!r}")
    rest = text[start:]
    token = "run: |\n"
    at = rest.find(token)
    if at < 0:
        raise AssertionError(f"step {step_name!r} has no run block")
    lines: list[str] = []
    for line in rest[at + len(token) :].splitlines():
        if line.startswith("          "):
            lines.append(line[10:])
        elif line.strip() == "":
            lines.append("")
        else:
            break
    if not lines:
        raise AssertionError(f"step {step_name!r} run block was empty")
    return "\n".join(lines) + "\n"


def _materialize(script: str, platform: str, binary: str) -> str:
    script = re.sub(
        r"\$\{\{\s*matrix\.chauffeur_platform\s*\}\}",
        platform,
        script,
    )
    return re.sub(
        r"\$\{\{\s*matrix\.chauffeur_name\s*\}\}",
        binary,
        script,
    )


def _archive(member: str, payload: bytes) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_STORED) as zipped:
        zipped.writestr(member, payload)
    return buf.getvalue()


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _pin_url(platform: str) -> str:
    return (
        "https://cdn.blazium.online/tools/chauffeur/"
        f"{platform}/{VERSION}/archive/default"
    )


def _write_pins(workspace: Path, platform: str, digest: str) -> None:
    path = workspace / "packaging" / "chauffeur" / "pins.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    doc = {
        "windows-amd64": {
            "version": VERSION,
            "url": _pin_url("windows-amd64"),
            "sha256": digest if platform == "windows-amd64" else "0" * 64,
        },
        "linux-amd64": {
            "version": VERSION,
            "url": _pin_url("linux-amd64"),
            "sha256": digest if platform == "linux-amd64" else "0" * 64,
        },
    }
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def _bring_up_loopback() -> None:
    """IFF_UP on lo. A fresh network namespace starts with lo down."""
    import fcntl
    import socket
    import struct

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    name = b"lo"
    flags = struct.unpack("16sH14s", fcntl.ioctl(sock.fileno(), 0x8913, struct.pack("16s16s", name, b"\x00" * 16))[:32])[1]
    flags |= 0x1
    fcntl.ioctl(sock.fileno(), 0x8914, struct.pack("16sH14s", name, flags, b"\x00" * 14))
    sock.close()


class _Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        path = self.path.split("?", 1)[0]
        if path == "/health":
            self._send(b"")
            return
        directory = Path(self.server.directory)  # type: ignore[attr-defined]
        counter = directory / "next"
        index = int(counter.read_text(encoding="utf-8") or "0") if counter.exists() else 0
        bodies = sorted(directory.glob("body*"))
        chosen = min(index, len(bodies) - 1)
        counter.write_text(str(index + 1), encoding="utf-8")
        with (directory / "paths.txt").open("a", encoding="utf-8") as handle:
            handle.write(path + "\n")
        self._send(bodies[chosen].read_bytes())

    def _send(self, body: bytes) -> None:
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt: str, *args) -> None:
        return


def _serve(directory: str) -> None:
    _bring_up_loopback()
    httpd = ThreadingHTTPServer(("127.0.0.1", FIXTURE_PORT), _Handler)
    httpd.directory = directory  # type: ignore[attr-defined]
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    Path(directory, "ready").write_text("1", encoding="utf-8")
    while not Path(directory, "stop").exists():
        threading.Event().wait(0.05)
    httpd.shutdown()


def _install_redirect(bin_dir: Path) -> None:
    """Point curl and urllib at the fixture. The bytes are still curl's or urllib's."""
    bin_dir.mkdir(parents=True)
    origin = f"http://127.0.0.1:{FIXTURE_PORT}"
    (bin_dir / "curl").write_text(
        "#!/usr/bin/env python3\n"
        "import os, sys\n"
        f"origin = {origin!r}\n"
        "args = []\n"
        "for arg in sys.argv[1:]:\n"
        "    if arg.startswith('https://cdn.blazium.online') or arg.startswith('http://cdn.blazium.online'):\n"
        "        arg = origin + arg.split('cdn.blazium.online', 1)[1]\n"
        "    args.append(arg)\n"
        "os.execv('/usr/bin/curl', ['/usr/bin/curl', *args])\n",
        encoding="utf-8",
    )
    (bin_dir / "curl").chmod(0o755)
    (bin_dir / "python").symlink_to("/usr/bin/python3")
    (bin_dir / "python3").symlink_to("/usr/bin/python3")
    (bin_dir / "sitecustomize.py").write_text(
        "import os\n"
        "from urllib.parse import urlsplit\n"
        "def _rewrite(url):\n"
        "    origin = os.environ.get('CHAUFFEUR_FIXTURE_ORIGIN', '')\n"
        "    if not origin or not isinstance(url, str):\n"
        "        return url\n"
        "    parts = urlsplit(url)\n"
        "    if (parts.hostname or '').rstrip('.').lower() != 'cdn.blazium.online':\n"
        "        return url\n"
        "    base = urlsplit(origin)\n"
        "    return base._replace(path=parts.path, query=parts.query, fragment=parts.fragment).geturl()\n"
        "def _install():\n"
        "    import urllib.request, http.client\n"
        "    orig_urlopen = urllib.request.urlopen\n"
        "    def urlopen(url, *args, **kwargs):\n"
        "        if isinstance(url, str):\n"
        "            url = _rewrite(url)\n"
        "        elif hasattr(url, 'full_url'):\n"
        "            url.full_url = _rewrite(url.full_url)\n"
        "        return orig_urlopen(url, *args, **kwargs)\n"
        "    urllib.request.urlopen = urlopen\n"
        "    orig_open = urllib.request.OpenerDirector.open\n"
        "    def open(self, fullurl, *args, **kwargs):\n"
        "        if isinstance(fullurl, str):\n"
        "            fullurl = _rewrite(fullurl)\n"
        "        elif hasattr(fullurl, 'full_url'):\n"
        "            fullurl.full_url = _rewrite(fullurl.full_url)\n"
        "        return orig_open(self, fullurl, *args, **kwargs)\n"
        "    urllib.request.OpenerDirector.open = open\n"
        "    orig_connect = http.client.HTTPSConnection.connect\n"
        "    def connect(self):\n"
        "        host = (self.host or '').split(':')[0].rstrip('.').lower()\n"
        "        if host == 'cdn.blazium.online':\n"
        "            base = urlsplit(os.environ['CHAUFFEUR_FIXTURE_ORIGIN'])\n"
        "            self.host = base.hostname\n"
        "            self.port = base.port\n"
        "            return http.client.HTTPConnection.connect(self)\n"
        "        return orig_connect(self)\n"
        "    http.client.HTTPSConnection.connect = connect\n"
        "_install()\n",
        encoding="utf-8",
    )


def _workspace(tmp: Path) -> Path:
    dest = tmp / "repo"
    shutil.copytree(
        ROOT,
        dest,
        ignore=shutil.ignore_patterns(".git", ".ci-test", "__pycache__", "*.pyc"),
    )
    return dest


def _run_download(workspace: Path, script: str, bodies: list[bytes]) -> dict:
    fixture = workspace / ".ci-test"
    if fixture.exists():
        shutil.rmtree(fixture)
    fixture.mkdir()
    for index, body in enumerate(bodies):
        (fixture / f"body{index}").write_bytes(body)
    _install_redirect(fixture / "bin")
    script_path = fixture / "download.sh"
    script_path.write_text(script, encoding="utf-8")
    driver = fixture / "driver.sh"
    ready = fixture / "ready"
    trace = fixture / "trace.txt"
    code = fixture / "exit.code"
    driver.write_text(
        "#!/bin/bash\n"
        "python3 "
        + repr(str(Path(__file__).resolve()))
        + " --serve "
        + repr(str(fixture))
        + " &\n"
        "spid=$!\n"
        "for _ in $(seq 1 100); do\n"
        f"  if [ -f {str(ready)!r} ]; then break; fi\n"
        "  sleep 0.02\n"
        "done\n"
        f"if [ ! -f {str(ready)!r} ]; then echo 'fixture server did not start' >&2; kill $spid 2>/dev/null || true; exit 99; fi\n"
        f"cd {str(workspace)!r}\n"
        "strace -f -s 512 -o "
        + repr(str(trace))
        + " -e trace=openat,creat,unlink,unlinkat bash "
        + repr(str(script_path))
        + "\n"
        "echo $? > "
        + repr(str(code))
        + "\n"
        "kill $spid 2>/dev/null || true\n"
        "wait $spid 2>/dev/null || true\n",
        encoding="utf-8",
    )
    driver.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = str(fixture / "bin") + os.pathsep + env.get("PATH", "")
    env["PYTHONPATH"] = str(fixture / "bin")
    env["CHAUFFEUR_FIXTURE_ORIGIN"] = f"http://127.0.0.1:{FIXTURE_PORT}"
    for key in ("http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "all_proxy"):
        env.pop(key, None)
    env["NO_PROXY"] = "*"
    proc = subprocess.run(
        ["unshare", "--user", "--map-root-user", "--net", "bash", str(driver)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=120,
    )
    if proc.returncode == 99 or not code.exists():
        raise AssertionError(
            "download harness failed\n"
            + proc.stdout
            + "\n"
            + proc.stderr
        )
    traced = trace.read_text(encoding="utf-8", errors="replace") if trace.exists() else ""
    if "openat" not in traced:
        raise AssertionError("strace did not record the download step\n" + proc.stderr + traced[:500])
    paths = []
    paths_file = fixture / "paths.txt"
    if paths_file.exists():
        paths = [line for line in paths_file.read_text(encoding="utf-8").splitlines() if line]
    return {
        "code": int(code.read_text(encoding="utf-8").strip() or "1"),
        "paths": paths,
        "trace": traced,
        "stdout": proc.stdout,
        "stderr": proc.stderr,
    }


def _writes_of(trace: str, binary_name: str) -> list[str]:
    hits = []
    pattern = re.compile(rf'(^|/){re.escape(binary_name)}("|\s|,)')
    for line in trace.splitlines():
        if not pattern.search(line):
            continue
        if any(flag in line for flag in ("O_WRONLY", "O_RDWR", "O_CREAT", "O_TRUNC", "unlink")):
            hits.append(line.strip())
    return hits


def _payload_files(workspace: Path, marker: bytes) -> list[Path]:
    """Extracted or installed copies of the archive member. The downloaded archive itself is the input."""
    roots = (
        workspace / ".ci" / "chauffeur",
        workspace / "export",
        workspace / "Program Files",
        workspace / "deb-root",
    )
    found = []
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if not path.is_file() or path.name == "archive":
                continue
            try:
                data = path.read_bytes()
            except OSError:
                continue
            if marker in data:
                found.append(path)
    return found


def _linux_env(workspace: Path) -> dict[str, str]:
    text = _workflow()
    block = text.split("  package-linux:", 1)[1].split("  release:", 1)[0]
    version = re.search(r'VERSION:\s*"([^"]+)"', block).group(1)
    arch = re.search(r"NFPM_ARCH:\s*(\S+)", block).group(1)
    env = os.environ.copy()
    env.update(
        {
            "VERSION": version,
            "NFPM_ARCH": arch,
            "SOURCE_DIR": str(workspace / "export"),
            "GITHUB_WORKSPACE": str(workspace),
        }
    )
    return env


def _stage_export_siblings(workspace: Path) -> None:
    export = workspace / "export"
    export.mkdir(parents=True, exist_ok=True)
    for name in ("BlaziumLauncher", "crash_reporter", "blazium-cli"):
        path = export / name
        if not path.exists():
            path.write_bytes(b"#!/bin/sh\nexit 0\n")
            path.chmod(0o755)


def _package_linux(workspace: Path) -> Path | None:
    export = workspace / "export" / "chauffeur"
    if not export.is_file():
        return None
    _stage_export_siblings(workspace)
    script = _run_block("Build deb")
    env = _linux_env(workspace)
    bin_dir = workspace / ".ci-test" / "bin"
    env["PATH"] = str(bin_dir) + os.pathsep + env.get("PATH", "")
    proc = subprocess.run(
        ["bash", "-c", script],
        cwd=workspace,
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=180,
    )
    deb = workspace / "dist" / f"blazium-games_{env['VERSION']}_amd64.deb"
    if proc.returncode != 0 or not deb.is_file():
        raise AssertionError(
            "linux packaging script failed\n" + proc.stdout + "\n" + proc.stderr
        )
    return deb


def _run_deb_chauffeur(deb: Path, workspace: Path) -> tuple[bytes, str]:
    root = workspace / "deb-root"
    if root.exists():
        shutil.rmtree(root)
    subprocess.run(["dpkg-deb", "-x", str(deb), str(root)], check=True)
    binary = root / "opt" / "blazium" / "bin" / "chauffeur"
    wrapper = root / "usr" / "bin" / "chauffeur"
    data = binary.read_bytes()
    for directory in (
        root / "usr" / "bin",
        root / "usr" / "lib" / "x86_64-linux-gnu",
        root / "usr" / "lib64",
        root / "bin",
    ):
        directory.mkdir(parents=True, exist_ok=True)
    shutil.copy("/usr/bin/dash", root / "usr" / "bin" / "dash")
    shutil.copy(
        "/usr/lib/x86_64-linux-gnu/libc.so.6",
        root / "usr" / "lib" / "x86_64-linux-gnu" / "libc.so.6",
    )
    shutil.copy(
        "/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2",
        root / "usr" / "lib" / "x86_64-linux-gnu" / "ld-linux-x86-64.so.2",
    )
    loader = root / "usr" / "lib64" / "ld-linux-x86-64.so.2"
    if loader.exists() or loader.is_symlink():
        loader.unlink()
    loader.symlink_to("../lib/x86_64-linux-gnu/ld-linux-x86-64.so.2")
    if not (root / "lib").exists():
        (root / "lib").symlink_to("usr/lib")
    if not (root / "lib64").exists():
        (root / "lib64").symlink_to("usr/lib64")
    shell = root / "bin" / "sh"
    if shell.exists() or shell.is_symlink():
        shell.unlink()
    shell.symlink_to("/usr/bin/dash")
    proc = subprocess.run(
        ["unshare", "--user", "--map-root-user", "--mount", "chroot", str(root), "/usr/bin/chauffeur"],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )
    if proc.returncode != 0:
        raise AssertionError(
            "packaged /usr/bin/chauffeur failed\n" + proc.stdout + "\n" + proc.stderr
        )
    packaged_wrapper = wrapper.read_bytes()
    repo_wrapper = (ROOT / "packaging" / "linux" / "games.sh").read_bytes()
    if packaged_wrapper != repo_wrapper:
        raise AssertionError("deb /usr/bin/chauffeur is not packaging/linux/games.sh")
    return data, proc.stdout


def _install_windows(workspace: Path) -> Path | None:
    iss = (ROOT / "packaging" / "windows" / "blazium-games.iss").read_text(encoding="utf-8")
    match = re.search(
        r'Source:\s*"\{#MyAppSourceDir\}\\chauffeur\.exe";\s*DestDir:\s*"([^"]+)"',
        iss,
    )
    if match is None:
        raise AssertionError("blazium-games.iss does not copy chauffeur.exe into the install")
    if "EnvAddPath(SharedRoot)" not in iss.split("procedure CurStepChanged", 1)[1]:
        raise AssertionError("installer no longer adds the shared Blazium directory to PATH")
    src = workspace / "export" / "chauffeur.exe"
    dest_dir = workspace / "Program Files" / "Blazium"
    dest_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy((ROOT / "packaging" / "windows" / "games.cmd"), dest_dir / "games.cmd")
    if not src.is_file():
        return None
    dest = dest_dir / "chauffeur.exe"
    shutil.copy(src, dest)
    return dest


def _scenario(tmp: Path, platform: str, binary: str, bodies: list[bytes], digest: str) -> dict:
    workspace = _workspace(tmp)
    _write_pins(workspace, platform, digest)
    script = _materialize(_run_block("Download chauffeur"), platform, binary)
    result = _run_download(workspace, script, bodies)
    export = workspace / "export" / binary
    result["export"] = export.read_bytes() if export.is_file() else None
    result["writes"] = _writes_of(result["trace"], binary)
    result["marker_files"] = _payload_files(workspace, BAD)
    result["installed"] = None
    result["ran"] = ""
    if platform == "linux-amd64" and export.is_file():
        deb = _package_linux(workspace)
        if deb is not None:
            installed, ran = _run_deb_chauffeur(deb, workspace)
            result["installed"] = installed
            result["ran"] = ran
    if platform == "windows-amd64":
        dest = _install_windows(workspace)
        if dest is not None and dest.is_file():
            result["installed"] = dest.read_bytes()
            result["ran"] = (dest.parent / "games.cmd").read_text(encoding="utf-8")
    result["workspace"] = workspace
    return result


def test_committed_chauffeur_pins_are_exact_versions():
    assert PINS.is_file(), "packaging/chauffeur/pins.json is the trusted record and is missing"
    doc = json.loads(PINS.read_text(encoding="utf-8"))
    for platform, _binary in _matrix():
        entry = doc.get(platform)
        assert isinstance(entry, dict), platform
        version = str(entry.get("version") or "")
        url = str(entry.get("url") or "")
        digest = str(entry.get("sha256") or "")
        assert version and version != "latest"
        assert "/latest/" not in url
        assert url == (
            "https://cdn.blazium.online/tools/chauffeur/"
            f"{platform}/{version}/archive/default"
        )
        assert re.fullmatch(r"[0-9a-f]{64}", digest)


@pytest.mark.parametrize("platform,binary", _matrix())
def test_substituted_chauffeur_archive_does_not_ship(platform: str, binary: str, tmp_path: Path):
    good_zip = _archive(binary, GOOD)
    bad_zip = _archive(binary, BAD)
    pinned = urlsplit(_pin_url(platform)).path
    problems: list[str] = []

    matched = _scenario(tmp_path / "match", platform, binary, [good_zip, bad_zip], _sha256(good_zip))
    if matched["paths"] != [pinned]:
        problems.append(
            f"pinned archive requests were {matched['paths']}, expected only {pinned} "
            "from packaging/chauffeur/pins.json"
        )
    if matched["code"] != 0:
        problems.append(
            f"download step rejected the archive that matches pins.json (exit {matched['code']})"
        )
    if matched["export"] != GOOD:
        problems.append("export binary is not the archive whose SHA-256 was trusted")
    if matched["installed"] not in (None, GOOD):
        problems.append("package installed bytes other than the trusted archive member")
    if platform == "linux-amd64" and "CHAUFFEUR_PINNED_BYTES" not in matched["ran"]:
        problems.append("installed /usr/bin/chauffeur did not run the trusted bytes")
    if "CHAUFFEUR_SUBSTITUTED_PAYLOAD" in matched["ran"]:
        problems.append("a later fetch was the binary that ran")

    mismatch = _scenario(tmp_path / "mismatch", platform, binary, [bad_zip], _sha256(good_zip))
    if mismatch["paths"] != [pinned]:
        problems.append(
            f"mismatch requests were {mismatch['paths']}, expected only {pinned}"
        )
    if mismatch["code"] == 0:
        problems.append("download step accepted an archive whose SHA-256 is not the pin")
    if mismatch["export"] is not None:
        problems.append("export/ received the substituted chauffeur binary")
    if mismatch["writes"]:
        problems.append("substituted binary was written before the step refused: " + mismatch["writes"][0])
    if mismatch["marker_files"]:
        problems.append(
            "substituted bytes were left on disk: "
            + ", ".join(str(path) for path in mismatch["marker_files"])
        )
    if mismatch["installed"] == BAD or (
        isinstance(mismatch["installed"], bytes) and BAD in mismatch["installed"]
    ):
        where = (
            "/opt/blazium/bin/chauffeur and /usr/bin/chauffeur"
            if platform == "linux-amd64"
            else r"{autopf}\Blazium\chauffeur.exe on the system PATH"
        )
        problems.append(f"substituted chauffeur was installed to {where}")
    if "CHAUFFEUR_SUBSTITUTED_PAYLOAD" in mismatch["ran"]:
        problems.append("running the installed chauffeur executed the substituted archive: " + mismatch["ran"].strip())

    assert not problems, "\n".join(problems)


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "--serve":
        _serve(sys.argv[2])
    else:
        raise SystemExit("run with pytest")
