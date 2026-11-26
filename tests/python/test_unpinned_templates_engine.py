"""Spec for the games_module templates pin.

The export job must build the launcher with the editor and export template
named by ci/templates.lock.json, and with no other release. The lock is a
JSON object:

    {"tag": "<templates tag>", "sha256": {"<asset filename>": "<lowercase hex sha256>", ...}}

`sha256` must cover the editor and the export template that the job actually
runs. Both names the workflow already accepts are valid template assets:
`matrix.template` and `matrix.template_alt`.

Before the editor is executed, the job has to hash the bytes it will execute
and the template bytes it will give that editor. Those digests have to match
the lock. A later read of the same path must not be what runs: the process
image has to be the bytes that were hashed. On a mismatch, or when the lock
is absent, the job has to stop without executing an editor, without writing
the export output, and without leaving the editor on `.ci/editor/`.

A successful export writes export/engine-provenance.json:

    {
      "tag": "<lock tag>",
      "editor_sha256": "<hex>",
      "template_sha256": "<hex>",
      "output_sha256": "<sha256 of the export output file>"
    }

The Linux package step, the Windows production sign step, and the release
step must refuse unless that provenance (or, for the release job,
dist/engine-provenance.json) matches the lock and the bytes about to be
packaged, signed, or published. The refusal has to happen before any
packaging, signing, or release API call, and before launcher.json is
written. The diagnostic those jobs print is:

    refusing unverified templates export

dist/engine-provenance.json is:

    {
      "tag": "<lock tag>",
      "editor_sha256": "<hex in the lock>",
      "template_sha256": "<hex in the lock>",
      "files": {"<installer filename>": "<lowercase hex sha256>"}
    }

These tests fail while the workflow still downloads the newest non-draft
templates-* release and executes it.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import textwrap
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "cicd.yml"
LOCK_PATH = Path("ci/templates.lock.json")
REFUSAL = "refusing unverified templates export"
TRUSTED_TAG = "templates-trusted"
CATALOG_PATH = Path("/tmp/games-module-templates-catalog.json")
PUBLISH_LOG = Path("/tmp/games-module-templates-publish.log")
TOKEN = "placeholder-token"

# Identity strings are embedded in the stand-in editor scripts. The TOCTOU
# interposition swaps a file only after a read of bytes that contain the
# trusted identity, so a hash of those bytes cannot be reused against a
# later open of the same path.
TRUSTED = "TRUSTED-ENGINE"
ATTACKER = "ATTACKER-ENGINE"
DECOY = "DECOY-ENGINE"
DRAFT = "DRAFT-ENGINE"
TAMPERED = "TAMPERED-ENGINE"


def _serve() -> None:
    descriptor = os.open(str(PUBLISH_LOG), os.O_CREAT | os.O_APPEND | os.O_WRONLY, 0o666)
    os.close(descriptor)
    os.chmod(PUBLISH_LOG, 0o666)
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args: object) -> None:
            return

        def _body(self) -> bytes:
            length = int(self.headers.get("Content-Length", "0") or "0")
            return self.rfile.read(length) if length else b""

        def _send(self, code: int, payload: bytes, content_type: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def _json(self, code: int, obj: Any) -> None:
            self._send(code, json.dumps(obj).encode(), "application/json")

        def _catalog(self) -> dict[str, Any]:
            return json.loads(CATALOG_PATH.read_text(encoding="utf-8"))

        def _note_publish(self) -> None:
            with PUBLISH_LOG.open("a", encoding="utf-8") as handle:
                handle.write(f"{self.command} {self.path}\n")

        def do_HEAD(self) -> None:  # noqa: N802
            code = 200 if self._release_for_path(self.path) else 404
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_GET(self) -> None:  # noqa: N802
            path = self.path.split("?", 1)[0]
            if path.startswith("/assets/"):
                blob = self._asset_bytes(path[len("/assets/") :])
                if blob is None:
                    self._json(404, {"message": "Not Found"})
                    return
                self._send(200, blob, "application/octet-stream")
                return
            release = self._release_for_path(path)
            if release is None:
                self._json(404, {"message": "Not Found"})
                return
            self._json(200, _rest_release(release))

        def do_POST(self) -> None:  # noqa: N802
            try:
                raw = self._body()
                path = self.path.split("?", 1)[0]
                if path == "/graphql" or path.endswith("/graphql"):
                    self._graphql(raw)
                    return
                if "/releases" in path:
                    self._note_publish()
                    if path.rstrip("/").endswith("/assets") or "/assets" in path:
                        name = "asset"
                        query = self.path.split("?", 1)[1] if "?" in self.path else ""
                        for part in query.split("&"):
                            if part.startswith("name="):
                                name = part.split("=", 1)[1]
                        self._json(201, {"name": name, "url": f"http://api.github.localhost/assets/{name}", "state": "uploaded"})
                        return
                    self._json(201, _created_release())
                    return
                self._json(404, {"message": "Not Found"})
            except Exception:
                import traceback

                Path("/tmp/templates-api-error.log").write_text(traceback.format_exc(), encoding="utf-8")
                self._json(500, {"message": "stand-in error"})

        def do_PATCH(self) -> None:  # noqa: N802
            self._body()
            if "/releases" in self.path:
                self._note_publish()
            self._json(200, _created_release())

        def do_DELETE(self) -> None:  # noqa: N802
            self._body()
            if "/releases" in self.path:
                self._note_publish()
            self._send(204, b"", "application/json")

        def _graphql(self, raw: bytes) -> None:
            try:
                payload = json.loads(raw.decode() or "{}")
            except json.JSONDecodeError:
                payload = {}
            query = payload.get("query") or ""
            if "Release_fields" in query:
                self._json(200, {"data": {"Release": {"fields": [{"name": "immutable"}, {"name": "tagName"}]}}})
                return
            if "RepositoryReleaseByTag" in query:
                self._json(200, {"data": {"repository": {"release": None}}})
                return
            if "RepositoryReleaseList" in query:
                direction = str((payload.get("variables") or {}).get("direction") or "DESC").upper()
                rows = sorted(
                    self._catalog()["releases"],
                    key=lambda item: item["created"],
                    reverse=direction != "ASC",
                )
                nodes = []
                for rel in rows:
                    nodes.append(
                        {
                            "name": rel["tag"],
                            "tagName": rel["tag"],
                            "isDraft": rel["draft"],
                            "isLatest": False,
                            "isPrerelease": rel["prerelease"],
                            "immutable": False,
                            "createdAt": rel["created"],
                            "publishedAt": None if rel["draft"] else rel["created"],
                        }
                    )
                self._json(
                    200,
                    {
                        "data": {
                            "repository": {
                                "releases": {
                                    "nodes": nodes,
                                    "pageInfo": {"hasNextPage": False, "endCursor": ""},
                                }
                            }
                        }
                    },
                )
                return
            self._json(200, {"data": {}})

        def _release_for_path(self, path: str) -> dict[str, Any] | None:
            marker = "/releases/tags/"
            if marker not in path:
                return None
            tag = path.split(marker, 1)[1].split("/", 1)[0]
            for rel in self._catalog()["releases"]:
                if rel["tag"] == tag and not rel["draft"]:
                    return rel
            return None

        def _asset_bytes(self, name: str) -> bytes | None:
            tag, _, asset = name.partition("/")
            if not asset:
                return None
            for rel in self._catalog()["releases"]:
                if rel["tag"] != tag:
                    continue
                encoded = (rel.get("assets") or {}).get(asset)
                if encoded is not None:
                    return _b64(encoded)
            return None

    class Server(ThreadingHTTPServer):
        address_family = socket.AF_INET6
        allow_reuse_address = True
        daemon_threads = True

        def server_bind(self) -> None:
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)
            super().server_bind()

    Server(("::", 80), Handler).serve_forever()


def _b64(text: str) -> bytes:
    import base64

    return base64.b64decode(text.encode())


def _rest_release(rel: dict[str, Any]) -> dict[str, Any]:
    import base64

    assets = []
    for name, encoded in (rel.get("assets") or {}).items():
        blob = base64.b64decode(encoded.encode())
        assets.append(
            {
                "url": f"http://api.github.localhost/assets/{rel['tag']}/{name}",
                "name": name,
                "browser_download_url": f"http://api.github.localhost/assets/{rel['tag']}/{name}",
                "node_id": "A_" + name,
                "size": len(blob),
                "content_type": "application/octet-stream",
                "state": "uploaded",
            }
        )
    return {
        "id": 1,
        "tag_name": rel["tag"],
        "name": rel["tag"],
        "draft": rel["draft"],
        "prerelease": rel["prerelease"],
        "immutable": False,
        "created_at": rel["created"],
        "published_at": rel["created"],
        "url": "http://api.github.localhost/repos/blazium-games/games_module/releases/1",
        "html_url": f"http://github.localhost/blazium-games/games_module/releases/tag/{rel['tag']}",
        "upload_url": "http://api.github.localhost/repos/blazium-games/games_module/releases/1/assets{?name,label}",
        "tarball_url": "http://api.github.localhost/tarball",
        "zipball_url": "http://api.github.localhost/zipball",
        "assets": assets,
        "author": {"login": "publisher", "node_id": "U1"},
    }


def _created_release() -> dict[str, Any]:
    return {
        "id": 7,
        "tag_name": "launcher",
        "name": "Blazium Games launcher",
        "draft": False,
        "prerelease": False,
        "url": "http://api.github.localhost/repos/blazium-games/games_launcher/releases/7",
        "html_url": "http://github.localhost/blazium-games/games_launcher/releases/tag/launcher",
        "upload_url": "http://api.github.localhost/repos/blazium-games/games_launcher/releases/7/assets{?name,label}",
        "assets": [],
        "author": {"login": "publisher", "node_id": "U1"},
    }


if __name__ == "__main__" and "--serve" in sys.argv:
    _serve()
    raise SystemExit(0)

import pytest


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _editor(identity: str) -> bytes:
    # The export step's argv is: --headless --path . --export-release PRESET OUT
    # The last argument is the export output path.
    return (
        "#!/bin/sh\n"
        f"printf '%s\\n' '{identity}' \"$*\" >> \"$BLAZIUM_EDITOR_LOG\"\n"
        "out=\n"
        "for arg in \"$@\"; do out=$arg; done\n"
        f"printf '%s\\n' '{identity}' > \"$out\"\n"
    ).encode()


def _template(identity: str) -> bytes:
    return f"template {identity}\n".encode()


def _encode_assets(assets: dict[str, bytes]) -> dict[str, str]:
    import base64

    return {name: base64.b64encode(blob).decode() for name, blob in assets.items()}


def _release(tag: str, created: str, assets: dict[str, bytes], *, draft: bool = False, prerelease: bool = False) -> dict[str, Any]:
    return {
        "tag": tag,
        "created": created,
        "draft": draft,
        "prerelease": prerelease,
        "assets": _encode_assets(assets),
    }


def _write_catalog(releases: list[dict[str, Any]]) -> None:
    payload = json.dumps({"releases": releases})
    tmp = CATALOG_PATH.with_suffix(".tmp")
    tmp.write_text(payload, encoding="utf-8")
    tmp.replace(CATALOG_PATH)


def _workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def _parse_matrix(text: str) -> list[dict[str, str]]:
    start = text.index("        include:\n")
    end = text.index("\n    steps:\n", start)
    rows: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    for line in text[start:end].splitlines():
        if line.startswith("          - "):
            if current:
                rows.append(current)
            current = {}
            key, value = line.split(":", 1)
            current[key.split("-", 1)[1].strip()] = value.strip()
        elif current is not None and line.startswith("            ") and ":" in line:
            key, value = line.strip().split(":", 1)
            current[key] = value.strip()
    if current:
        rows.append(current)
    return rows


def _parse_jobs(text: str) -> dict[str, dict[str, Any]]:
    lines = text.splitlines()
    jobs: dict[str, dict[str, Any]] = {}
    job: dict[str, Any] | None = None
    step: dict[str, Any] | None = None
    i = 0
    in_jobs = False
    while i < len(lines):
        line = lines[i]
        if line.startswith("jobs:"):
            in_jobs = True
            i += 1
            continue
        if not in_jobs:
            i += 1
            continue
        if re.match(r"^  [A-Za-z0-9_-]+:\s*$", line):
            name = line.strip()[:-1]
            job = {"name": name, "if": None, "steps": []}
            jobs[name] = job
            step = None
            i += 1
            continue
        if job is None:
            i += 1
            continue
        if re.match(r"^    if:\s*", line) and step is None:
            job["if"] = line.split(":", 1)[1].strip()
            i += 1
            continue
        if line.startswith("      - "):
            step = {"name": "", "id": "", "if": None, "shell": None, "env": {}, "run": None, "uses": None}
            job["steps"].append(step)
            rest = line[8:]
            if rest.startswith("name:"):
                step["name"] = rest.split(":", 1)[1].strip().strip('"')
            elif rest.startswith("uses:"):
                step["uses"] = rest.split(":", 1)[1].strip()
            i += 1
            continue
        if step is None:
            i += 1
            continue
        stripped = line.strip()
        if stripped.startswith("name:") and not step["name"]:
            step["name"] = stripped.split(":", 1)[1].strip().strip('"')
        elif stripped.startswith("id:"):
            step["id"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("if:"):
            step["if"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("uses:"):
            step["uses"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("shell:"):
            step["shell"] = stripped.split(":", 1)[1].strip()
        elif stripped.startswith("env:"):
            i += 1
            while i < len(lines) and lines[i].startswith("          "):
                env_line = lines[i].strip()
                if ":" in env_line:
                    key, value = env_line.split(":", 1)
                    step["env"][key.strip()] = value.strip().strip('"')
                i += 1
            continue
        elif stripped.startswith("run:"):
            inline = stripped.split(":", 1)[1].strip()
            if inline and inline != "|":
                step["run"] = inline
                i += 1
                continue
            i += 1
            body: list[str] = []
            while i < len(lines) and (lines[i].startswith("          ") or lines[i].strip() == ""):
                # A blank line ends the block only when the next non-empty
                # line is a sibling key or a new step. Keep blank lines that
                # sit between indented body lines.
                if lines[i].strip() == "":
                    look = i + 1
                    while look < len(lines) and lines[look].strip() == "":
                        look += 1
                    if look >= len(lines) or not lines[look].startswith("          "):
                        break
                body.append(lines[i])
                i += 1
            indents = [len(item) - len(item.lstrip(" ")) for item in body if item.strip()]
            trim = min(indents) if indents else 0
            step["run"] = "\n".join(item[trim:] if item.strip() else "" for item in body) + "\n"
            continue
        i += 1
    return jobs


def _substitute(script: str, values: dict[str, str]) -> str:
    def repl(match: re.Match[str]) -> str:
        key = match.group(1).strip()
        if key not in values:
            raise AssertionError(f"workflow expression was not substituted: {key}")
        return values[key]

    rendered = re.sub(r"\$\{\{\s*([^}]+?)\s*\}\}", repl, script)
    if "${{" in rendered:
        raise AssertionError(rendered)
    return rendered


def _production_context() -> dict[str, str]:
    return {"github.event_name": "push", "github.ref": "refs/heads/main"}


def _eval_if(expression: str | None, outputs: dict[str, str]) -> bool:
    if not expression:
        return True
    ctx = dict(_production_context())
    ctx.update(outputs)

    def atom(token: str) -> str:
        token = token.strip()
        if len(token) >= 2 and token[0] == token[-1] and token[0] in "'\"":
            return token[1:-1]
        if token in ctx:
            return str(ctx[token])
        if token in {"true", "false"}:
            return token
        return ""

    def compare(piece: str) -> bool:
        for op in ("!=", "=="):
            if op in piece:
                left, right = piece.split(op, 1)
                same = atom(left) == atom(right)
                return same if op == "==" else not same
        return atom(piece) not in {"", "false"}

    or_terms = []
    for or_part in expression.split("||"):
        and_ok = all(compare(part) for part in or_part.split("&&"))
        or_terms.append(and_ok)
    return any(or_terms)


def _jobs() -> dict[str, dict[str, Any]]:
    return _parse_jobs(_workflow_text())


def _matrix() -> list[dict[str, str]]:
    rows = _parse_matrix(_workflow_text())
    assert {row["platform"] for row in rows} == {"windows", "linuxbsd"}
    return rows


def _row(platform: str) -> dict[str, str]:
    for row in _matrix():
        if row["platform"] == platform:
            return row
    raise AssertionError(platform)


def _step(job: str, name: str) -> dict[str, Any]:
    for step in _jobs()[job]["steps"]:
        if step["name"] == name:
            return step
    raise AssertionError(f"{job} has no step {name}")


def _assert_job_runs_on_main_push(job: str) -> None:
    expression = _jobs()[job]["if"]
    assert expression
    assert _eval_if(expression, {})


def _bash_argv(shell: str | None) -> list[str]:
    # actions/runner v2.329.0 ScriptHandler.cs: when shell is unset on Linux,
    # bash is selected and the argument format is the bash entry
    # `--noprofile --norc -e -o pipefail`. When shell is exactly `bash`,
    # the same file uses the `sh` argument format `-e` instead.
    if shell == "bash":
        return ["bash", "--noprofile", "--norc", "-e"]
    return ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail"]


def _run_script(
    script: str,
    cwd: Path,
    env: dict[str, str],
    *,
    shell: str | None,
) -> subprocess.CompletedProcess[str]:
    path = cwd / ".step.sh"
    path.write_text(script, encoding="utf-8")
    path.chmod(0o755)
    return subprocess.run(
        [*_bash_argv(shell), str(path)],
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def _base_env(workspace: Path, log_path: Path) -> dict[str, str]:
    config = workspace / ".gh-config"
    config.mkdir(parents=True, exist_ok=True)
    return {
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "HOME": str(workspace / ".home"),
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "GH_HOST": "github.localhost",
        "GH_TOKEN": TOKEN,
        "GH_PROMPT_DISABLED": "1",
        "GH_CONFIG_DIR": str(config),
        "GITHUB_WORKSPACE": str(workspace),
        "GITHUB_REPOSITORY": "blazium-games/games_launcher",
        "GITHUB_SHA": "30de23635f6fcfd942cb38341b81bb19ac6ff1fb",
        "BLAZIUM_EDITOR_LOG": str(log_path),
        "TMPDIR": "/tmp",
    }


def _prepare_workspace(tmp_path: Path) -> Path:
    workspace = tmp_path / "repo"
    shutil.copytree(
        ROOT,
        workspace,
        ignore=shutil.ignore_patterns(".git", ".pytest_cache", "__pycache__", "export", "dist", ".ci"),
        dirs_exist_ok=False,
    )
    (workspace / ".home").mkdir()
    return workspace


def _write_lock(workspace: Path, hashes: dict[str, str]) -> None:
    path = workspace / LOCK_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"tag": TRUSTED_TAG, "sha256": hashes}, indent=2) + "\n", encoding="utf-8")


def _platform_assets(row: dict[str, str], editor_id: str, template_id: str, *, alt: bool = False) -> dict[str, bytes]:
    template_name = row["template_alt"] if alt else row["template"]
    return {
        row["editor"]: _editor(editor_id),
        template_name: _template(template_id),
    }


def _merged_assets(editor_id: str, template_id: str, *, alt: bool = False) -> dict[str, bytes]:
    assets: dict[str, bytes] = {}
    for row in _matrix():
        assets.update(_platform_assets(row, editor_id, template_id, alt=alt))
    return assets


def _attacker_catalog(trusted_assets: dict[str, bytes]) -> list[dict[str, Any]]:
    attacker_assets = _merged_assets(ATTACKER, ATTACKER)
    decoy_assets = _merged_assets(DECOY, DECOY)
    draft_assets = _merged_assets(DRAFT, DRAFT)
    return [
        _release("engine-evil", "2026-12-20T00:00:00Z", decoy_assets),
        _release("templates-draft", "2026-12-10T00:00:00Z", draft_assets, draft=True),
        _release("templates-attacker", "2026-11-01T00:00:00Z", attacker_assets, prerelease=True),
        _release(TRUSTED_TAG, "2026-01-01T00:00:00Z", trusted_assets),
    ]


def _run_export(workspace: Path, row: dict[str, str], extra_env: dict[str, str] | None = None) -> dict[str, Any]:
    _assert_job_runs_on_main_push("export")
    download = _step("export", "Download games_module templates")
    export = _step("export", "Export")
    assert download["shell"] == "bash"
    assert export["shell"] == "bash"
    values = {f"matrix.{key}": value for key, value in row.items()}
    log_path = workspace / "editor-ran.log"
    env = _base_env(workspace, log_path)
    if extra_env:
        env.update(extra_env)
    output_file = workspace / "github-output.txt"
    env["GITHUB_OUTPUT"] = str(output_file)
    output_file.write_text("", encoding="utf-8")
    download_proc = _run_script(_substitute(download["run"], values), workspace, env, shell="bash")
    ready = ""
    for line in output_file.read_text(encoding="utf-8").splitlines():
        if line.startswith("ready="):
            ready = line.split("=", 1)[1].strip()
    export_proc = None
    if download_proc.returncode == 0 and ready == "true":
        output_file.write_text("", encoding="utf-8")
        export_proc = _run_script(_substitute(export["run"], values), workspace, env, shell="bash")
    return {
        "download": download_proc,
        "export": export_proc,
        "ready": ready,
        "log": log_path,
        "output": workspace / row["out"],
        "editor_path": workspace / ".ci" / "editor" / row["editor"],
    }


def _combined(result: dict[str, Any]) -> str:
    parts = [result["download"].stdout, result["download"].stderr]
    if result["export"] is not None:
        parts.extend([result["export"].stdout, result["export"].stderr])
    return "\n".join(parts)


def _executed(result: dict[str, Any]) -> str:
    log: Path = result["log"]
    if not log.exists():
        return ""
    return log.read_text(encoding="utf-8")


def _assert_not_executed(result: dict[str, Any]) -> None:
    executed = _executed(result)
    assert executed == ""
    assert not result["output"].exists()
    assert not result["editor_path"].exists()
    for identity in (ATTACKER, DECOY, DRAFT, TAMPERED, TRUSTED):
        assert identity not in executed


def _assert_trusted_export(result: dict[str, Any], row: dict[str, str], editor: bytes, template: bytes) -> None:
    assert result["download"].returncode == 0, _combined(result)
    assert result["export"] is not None, _combined(result)
    assert result["export"].returncode == 0, _combined(result)
    executed = _executed(result)
    assert executed.splitlines()
    assert executed.splitlines()[0] == TRUSTED, executed
    assert "--export-release" in executed
    assert row["preset"] in executed
    for identity in (ATTACKER, DECOY, DRAFT, TAMPERED):
        assert identity not in executed
    assert result["output"].read_bytes() == (TRUSTED + "\n").encode()
    provenance_path = result["output"].parent / "engine-provenance.json"
    assert provenance_path.is_file(), executed
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    assert provenance["tag"] == TRUSTED_TAG
    assert provenance["editor_sha256"] == _sha(editor)
    assert provenance["template_sha256"] == _sha(template)
    assert provenance["output_sha256"] == _sha(result["output"].read_bytes())


@pytest.fixture(scope="session", autouse=True)
def _templates_api() -> Any:
    CATALOG_PATH.write_text(json.dumps({"releases": []}), encoding="utf-8")
    subprocess.run(["sudo", "rm", "-f", str(PUBLISH_LOG)], check=False, capture_output=True, text=True)
    subprocess.run(["sudo", "fuser", "-k", "80/tcp"], check=False, capture_output=True, text=True)
    proc = subprocess.Popen(
        ["sudo", "python3", str(Path(__file__).resolve()), "--serve"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    deadline = subprocess.run(["bash", "-c", "for i in $(seq 1 50); do curl -sf -o /dev/null http://api.github.localhost/graphql -X POST -H 'content-type: application/json' --data '{\"query\":\"query Release_fields{Release: __type(name: \\\"Release\\\"){fields{name}}}\"}' && exit 0; sleep 0.1; done; exit 1"], check=False)
    if deadline.returncode != 0:
        proc.kill()
        raise RuntimeError("templates API stand-in did not start")
    yield
    subprocess.run(["sudo", "kill", str(proc.pid)], check=False, capture_output=True)
    proc.wait(timeout=5)


@pytest.fixture(scope="session")
def _preload(tmp_path_factory: pytest.TempPathFactory) -> Path:
    source = r"""
        #define _GNU_SOURCE
        #include <dlfcn.h>
        #include <fcntl.h>
        #include <stdarg.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        #define MAX_FD 4096
        static int (*real_open)(const char *, int, ...);
        static int (*real_openat)(int, const char *, int, ...);
        static ssize_t (*real_read)(int, void *, size_t);
        static int (*real_close)(int);
        static ssize_t (*real_copy_file_range)(int, loff_t *, int, loff_t *, size_t, unsigned int);
        static char *fd_path[MAX_FD];
        static int fd_reads[MAX_FD];
        static int fd_write[MAX_FD];
        static void init(void) {
            if (real_open) return;
            real_open = dlsym(RTLD_NEXT, "open");
            real_openat = dlsym(RTLD_NEXT, "openat");
            real_read = dlsym(RTLD_NEXT, "read");
            real_close = dlsym(RTLD_NEXT, "close");
            real_copy_file_range = dlsym(RTLD_NEXT, "copy_file_range");
        }
        static int under_watch(const char *path) {
            const char *root = getenv("TOCTOU_ROOT");
            if (!root || !path) return 0;
            size_t n = strlen(root);
            if (strncmp(path, root, n) != 0) return 0;
            const char *rest = path + n;
            return strncmp(rest, "/.ci/", 5) == 0 || strncmp(rest, "/templates/", 11) == 0;
        }
        static char *absolute(const char *path) {
            if (!path) return NULL;
            if (path[0] == '/') return strdup(path);
            char cwd[4096];
            if (!getcwd(cwd, sizeof cwd)) return strdup(path);
            size_t n = strlen(cwd) + strlen(path) + 2;
            char *out = malloc(n);
            snprintf(out, n, "%s/%s", cwd, path);
            return out;
        }
        static void remember(int fd, const char *path, int flags) {
            if (fd < 0 || fd >= MAX_FD) return;
            free(fd_path[fd]);
            fd_path[fd] = NULL;
            fd_reads[fd] = 0;
            fd_write[fd] = 0;
            char *full = absolute(path);
            if (full && under_watch(full)) {
                fd_path[fd] = full;
                fd_write[fd] = (flags & O_ACCMODE) != O_RDONLY;
            } else {
                free(full);
            }
        }
        static void swap_file(const char *path) {
            const char *needle = getenv("TOCTOU_NEEDLE");
            const char *payload = getenv("TOCTOU_PAYLOAD");
            if (!needle || !payload) return;
            int in = real_open(path, O_RDONLY, 0);
            if (in < 0) return;
            char buf[8192];
            ssize_t n = real_read(in, buf, sizeof buf - 1);
            real_close(in);
            if (n < 0) return;
            buf[n] = 0;
            if (!strstr(buf, needle)) return;
            int src = real_open(payload, O_RDONLY, 0);
            if (src < 0) return;
            int out = real_open(path, O_WRONLY | O_TRUNC, 0);
            if (out < 0) { real_close(src); return; }
            for (;;) {
                char block[4096];
                ssize_t got = real_read(src, block, sizeof block);
                if (got <= 0) break;
                ssize_t off = 0;
                while (off < got) {
                    ssize_t wrote = write(out, block + off, (size_t)(got - off));
                    if (wrote < 0) break;
                    off += wrote;
                }
            }
            real_close(src);
            real_close(out);
        }
        int open(const char *path, int flags, ...) {
            init();
            mode_t mode = 0;
            if (flags & (O_CREAT)) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
            int fd = real_open(path, flags, mode);
            remember(fd, path, flags);
            return fd;
        }
        int open64(const char *path, int flags, ...) {
            init();
            mode_t mode = 0;
            if (flags & (O_CREAT)) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
            int fd = real_open(path, flags, mode);
            remember(fd, path, flags);
            return fd;
        }
        int openat(int dirfd, const char *path, int flags, ...) {
            init();
            mode_t mode = 0;
            if (flags & (O_CREAT)) { va_list ap; va_start(ap, flags); mode = (mode_t)va_arg(ap, int); va_end(ap); }
            int fd = real_openat(dirfd, path, flags, mode);
            if (path && path[0] == '/') remember(fd, path, flags);
            else if (dirfd == AT_FDCWD) remember(fd, path, flags);
            return fd;
        }
        int openat64(int dirfd, const char *path, int flags, ...) {
            return openat(dirfd, path, flags);
        }
        ssize_t read(int fd, void *buf, size_t n) {
            init();
            ssize_t got = real_read(fd, buf, n);
            if (got > 0 && fd >= 0 && fd < MAX_FD && fd_path[fd]) fd_reads[fd] += (int)got;
            return got;
        }
        ssize_t copy_file_range(int fd_in, loff_t *off_in, int fd_out, loff_t *off_out, size_t len, unsigned int flags) {
            init();
            ssize_t got = real_copy_file_range(fd_in, off_in, fd_out, off_out, len, flags);
            if (got > 0 && fd_in >= 0 && fd_in < MAX_FD && fd_path[fd_in]) fd_reads[fd_in] += (int)got;
            return got;
        }
        int close(int fd) {
            init();
            char *path = NULL;
            int should = 0;
            if (fd >= 0 && fd < MAX_FD) {
                should = fd_path[fd] && fd_reads[fd] > 0 && !fd_write[fd];
                if (should) path = strdup(fd_path[fd]);
                free(fd_path[fd]);
                fd_path[fd] = NULL;
                fd_reads[fd] = 0;
                fd_write[fd] = 0;
            }
            int rc = real_close(fd);
            if (should && path) swap_file(path);
            free(path);
            return rc;
        }
    """
    directory = tmp_path_factory.mktemp("preload")
    c_path = directory / "toctou.c"
    so_path = directory / "toctou.so"
    c_path.write_text(textwrap.dedent(source), encoding="utf-8")
    build = subprocess.run(
        ["gcc", "-shared", "-fPIC", "-O2", "-o", str(so_path), str(c_path), "-ldl"],
        capture_output=True,
        text=True,
        check=False,
    )
    assert build.returncode == 0, build.stderr
    probe_dir = directory / "probe"
    (probe_dir / ".ci").mkdir(parents=True)
    target = probe_dir / ".ci" / "editor"
    target.write_bytes(_editor(TRUSTED))
    payload = directory / "payload"
    payload.write_bytes(_editor(ATTACKER))
    env = os.environ.copy()
    env.update(
        {
            "LD_PRELOAD": str(so_path),
            "TOCTOU_ROOT": str(probe_dir),
            "TOCTOU_NEEDLE": TRUSTED,
            "TOCTOU_PAYLOAD": str(payload),
        }
    )
    probe = subprocess.run(
        ["python3", "-c", "open('.ci/editor','rb').read()"],
        cwd=probe_dir,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert probe.returncode == 0, probe.stderr
    assert ATTACKER.encode() in target.read_bytes()
    return so_path


@pytest.mark.parametrize("platform", ["windows", "linuxbsd"])
def test_export_uses_pinned_release_not_newer_templates_tag(tmp_path: Path, platform: str) -> None:
    row = _row(platform)
    trusted_assets = _merged_assets(TRUSTED, TRUSTED)
    editor = trusted_assets[row["editor"]]
    template = trusted_assets[row["template"]]
    _write_catalog(_attacker_catalog(trusted_assets))
    workspace = _prepare_workspace(tmp_path)
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted_assets.items()})
    result = _run_export(workspace, row)
    _assert_trusted_export(result, row, editor, template)


@pytest.mark.parametrize("platform", ["windows", "linuxbsd"])
def test_export_accepts_pinned_alternate_template_name(tmp_path: Path, platform: str) -> None:
    row = _row(platform)
    trusted_assets = _merged_assets(TRUSTED, TRUSTED, alt=True)
    editor = trusted_assets[row["editor"]]
    template = trusted_assets[row["template_alt"]]
    _write_catalog(_attacker_catalog(trusted_assets))
    workspace = _prepare_workspace(tmp_path)
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted_assets.items()})
    result = _run_export(workspace, row)
    _assert_trusted_export(result, row, editor, template)


@pytest.mark.parametrize("platform", ["windows", "linuxbsd"])
def test_export_refuses_tampered_editor_on_the_pinned_tag(tmp_path: Path, platform: str) -> None:
    row = _row(platform)
    trusted = _merged_assets(TRUSTED, TRUSTED)
    tampered = dict(trusted)
    tampered[row["editor"]] = _editor(TAMPERED)
    _write_catalog([_release(TRUSTED_TAG, "2026-01-01T00:00:00Z", tampered)])
    workspace = _prepare_workspace(tmp_path)
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted.items()})
    result = _run_export(workspace, row)
    _assert_not_executed(result)


@pytest.mark.parametrize("platform", ["windows", "linuxbsd"])
def test_export_refuses_tampered_template_on_the_pinned_tag(tmp_path: Path, platform: str) -> None:
    row = _row(platform)
    trusted = _merged_assets(TRUSTED, TRUSTED)
    tampered = dict(trusted)
    tampered[row["template"]] = _template(TAMPERED)
    _write_catalog([_release(TRUSTED_TAG, "2026-01-01T00:00:00Z", tampered)])
    workspace = _prepare_workspace(tmp_path)
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted.items()})
    result = _run_export(workspace, row)
    _assert_not_executed(result)


@pytest.mark.parametrize("platform", ["windows", "linuxbsd"])
def test_export_refuses_when_the_lock_is_absent(tmp_path: Path, platform: str) -> None:
    row = _row(platform)
    trusted = _merged_assets(TRUSTED, TRUSTED)
    _write_catalog(_attacker_catalog(trusted))
    workspace = _prepare_workspace(tmp_path)
    lock = workspace / LOCK_PATH
    if lock.exists():
        lock.unlink()
    result = _run_export(workspace, row)
    _assert_not_executed(result)


@pytest.mark.parametrize("platform", ["windows", "linuxbsd"])
def test_export_runs_the_hashed_bytes_when_the_path_is_replaced(
    tmp_path: Path, platform: str, _preload: Path
) -> None:
    row = _row(platform)
    trusted_assets = _merged_assets(TRUSTED, TRUSTED)
    editor = trusted_assets[row["editor"]]
    template = trusted_assets[row["template"]]
    _write_catalog([_release(TRUSTED_TAG, "2026-01-01T00:00:00Z", trusted_assets)])
    workspace = _prepare_workspace(tmp_path)
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted_assets.items()})
    payload = tmp_path / "attacker-editor"
    payload.write_bytes(_editor(ATTACKER))
    result = _run_export(
        workspace,
        row,
        {
            "LD_PRELOAD": str(_preload),
            "TOCTOU_ROOT": str(workspace),
            "TOCTOU_NEEDLE": TRUSTED,
            "TOCTOU_PAYLOAD": str(payload),
        },
    )
    _assert_trusted_export(result, row, editor, template)


def _curl_wrapper(directory: Path, log_path: Path) -> None:
    path = directory / "curl"
    path.write_text(
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$*\" >> {log_path}\n"
        "exit 0\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


def _run_named_step(job: str, name: str, workspace: Path, env: dict[str, str], values: dict[str, str]) -> subprocess.CompletedProcess[str]:
    step = _step(job, name)
    assert step["run"]
    script = _substitute(step["run"], values)
    for key, value in step["env"].items():
        if value.startswith("${{") and "secrets." in value:
            env.setdefault(key, "placeholder")
        else:
            env.setdefault(key, _substitute(value, values))
    return _run_script(script, workspace, env, shell=step["shell"])


def _export_provenance(editor: bytes, template: bytes, output: bytes) -> dict[str, Any]:
    return {
        "tag": TRUSTED_TAG,
        "editor_sha256": _sha(editor),
        "template_sha256": _sha(template),
        "output_sha256": _sha(output),
    }


def test_linux_package_refuses_an_unverified_export(tmp_path: Path) -> None:
    _assert_job_runs_on_main_push("package-linux")
    workspace = _prepare_workspace(tmp_path)
    trusted = _merged_assets(TRUSTED, TRUSTED)
    row = _row("linuxbsd")
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted.items()})
    export = workspace / "export"
    export.mkdir()
    launcher = _editor(ATTACKER)
    (export / "BlaziumLauncher").write_bytes(launcher)
    for name in ("chauffeur", "blazium-cli", "crash_reporter"):
        (export / name).write_bytes(b"#!/bin/sh\n")
    (export / "VERSION").write_text("0.1.0\n", encoding="utf-8")
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    curl_log = tmp_path / "curl.log"
    _curl_wrapper(bin_dir, curl_log)
    env = _base_env(workspace, workspace / "editor-ran.log")
    env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
    env["GITHUB_OUTPUT"] = str(workspace / "github-output.txt")
    proc = _run_named_step(
        "package-linux",
        "Build deb",
        workspace,
        env,
        {"github.workspace": str(workspace)},
    )
    assert proc.returncode != 0, proc.stdout + proc.stderr
    assert REFUSAL in proc.stdout + proc.stderr
    assert not curl_log.exists()
    assert not (workspace / "dist" / "blazium-games_0.1.0_amd64.deb").exists()


def test_linux_package_builds_a_verified_export(tmp_path: Path) -> None:
    workspace = _prepare_workspace(tmp_path)
    trusted = _merged_assets(TRUSTED, TRUSTED)
    row = _row("linuxbsd")
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted.items()})
    export = workspace / "export"
    export.mkdir()
    launcher = (TRUSTED + "\n").encode()
    (export / "BlaziumLauncher").write_bytes(launcher)
    for name in ("chauffeur", "blazium-cli", "crash_reporter"):
        (export / name).write_bytes(b"#!/bin/sh\n")
    (export / "VERSION").write_text("0.1.0\n", encoding="utf-8")
    (export / "engine-provenance.json").write_text(
        json.dumps(_export_provenance(trusted[row["editor"]], trusted[row["template"]], launcher)) + "\n",
        encoding="utf-8",
    )
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    curl_log = tmp_path / "curl.log"
    _curl_wrapper(bin_dir, curl_log)
    env = _base_env(workspace, workspace / "editor-ran.log")
    env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
    env["GITHUB_OUTPUT"] = str(workspace / "github-output.txt")
    proc = _run_named_step(
        "package-linux",
        "Build deb",
        workspace,
        env,
        {"github.workspace": str(workspace)},
    )
    output = proc.stdout + proc.stderr
    assert REFUSAL not in output
    assert curl_log.exists()


def _run_windows_sign(workspace: Path) -> dict[str, Any]:
    _assert_job_runs_on_main_push("package-windows")
    env = _base_env(workspace, workspace / "editor-ran.log")
    outputs: dict[str, str] = {}
    reached_signer = False
    transcripts: list[str] = []
    for step in _jobs()["package-windows"]["steps"]:
        if step["uses"] and "sslcom-code-signer" in step["uses"]:
            if _eval_if(step["if"], outputs):
                reached_signer = True
            break
        if not step["run"] or step["shell"] not in {None, "bash"}:
            continue
        if not _eval_if(step["if"], outputs):
            continue
        output_file = workspace / f"output-{step['id'] or step['name']}.txt"
        env["GITHUB_OUTPUT"] = str(output_file)
        output_file.write_text("", encoding="utf-8")
        for key, value in step["env"].items():
            if "secrets." in value:
                env[key] = "placeholder"
            else:
                env[key] = _substitute(value, {"github.workspace": str(workspace)})
        proc = _run_script(_substitute(step["run"], {"github.workspace": str(workspace)}), workspace, env, shell=step["shell"])
        transcripts.append(proc.stdout + proc.stderr)
        for line in output_file.read_text(encoding="utf-8").splitlines():
            if "=" in line and step["id"]:
                key, value = line.split("=", 1)
                outputs[f"steps.{step['id']}.outputs.{key.strip()}"] = value.strip()
        outcome = "success" if proc.returncode == 0 else "failure"
        if step["id"]:
            outputs[f"steps.{step['id']}.outcome"] = outcome
        if proc.returncode != 0:
            break
    return {"reached_signer": reached_signer, "output": "\n".join(transcripts), "outputs": outputs}


def _plant_windows_export(workspace: Path, launcher: bytes, provenance: dict[str, Any] | None) -> None:
    export = workspace / "export"
    export.mkdir()
    (export / "BlaziumLauncher.exe").write_bytes(launcher)
    if provenance is not None:
        (export / "engine-provenance.json").write_text(json.dumps(provenance) + "\n", encoding="utf-8")


def test_windows_production_does_not_sign_an_unverified_export(tmp_path: Path) -> None:
    workspace = _prepare_workspace(tmp_path)
    trusted = _merged_assets(TRUSTED, TRUSTED)
    row = _row("windows")
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted.items()})
    _plant_windows_export(workspace, _editor(ATTACKER), None)
    result = _run_windows_sign(workspace)
    assert not result["reached_signer"]
    assert REFUSAL in result["output"]


def test_windows_production_reaches_signing_for_a_verified_export(tmp_path: Path) -> None:
    workspace = _prepare_workspace(tmp_path)
    trusted = _merged_assets(TRUSTED, TRUSTED)
    row = _row("windows")
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted.items()})
    launcher = (TRUSTED + "\n").encode()
    _plant_windows_export(
        workspace,
        launcher,
        _export_provenance(trusted[row["editor"]], trusted[row["template"]], launcher),
    )
    result = _run_windows_sign(workspace)
    assert REFUSAL not in result["output"]
    assert result["reached_signer"]
    assert result["outputs"].get("steps.sign.outputs.sign") == "true"


def _reset_publish_log() -> None:
    PUBLISH_LOG.write_text("", encoding="utf-8")


def _release_provenance(files: dict[str, bytes], editor: bytes, template: bytes) -> dict[str, Any]:
    return {
        "tag": TRUSTED_TAG,
        "editor_sha256": _sha(editor),
        "template_sha256": _sha(template),
        "files": {name: _sha(blob) for name, blob in files.items()},
    }


def _run_release(workspace: Path) -> subprocess.CompletedProcess[str]:
    env = _base_env(workspace, workspace / "editor-ran.log")
    env["GITHUB_OUTPUT"] = str(workspace / "github-output.txt")
    return _run_named_step("release", "GitHub release", workspace, env, {})


def test_release_does_not_publish_an_unverified_installer(tmp_path: Path) -> None:
    _assert_job_runs_on_main_push("release")
    workspace = _prepare_workspace(tmp_path)
    trusted = _merged_assets(TRUSTED, TRUSTED)
    row = _row("linuxbsd")
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted.items()})
    dist = workspace / "dist"
    dist.mkdir()
    installer = _editor(ATTACKER)
    (dist / "blazium-games_0.1.0_amd64.deb").write_bytes(installer)
    (dist / "engine-provenance.json").write_text(
        json.dumps(
            {
                "tag": TRUSTED_TAG,
                "editor_sha256": _sha(b"not-the-locked-editor"),
                "template_sha256": _sha(trusted[row["template"]]),
                "files": {"blazium-games_0.1.0_amd64.deb": _sha(installer)},
            }
        )
        + "\n",
        encoding="utf-8",
    )
    _reset_publish_log()
    proc = _run_release(workspace)
    assert proc.returncode != 0, proc.stdout + proc.stderr
    assert REFUSAL in proc.stdout + proc.stderr
    assert not (dist / "launcher.json").exists()
    assert PUBLISH_LOG.read_text(encoding="utf-8") == ""


def test_release_publishes_a_verified_installer(tmp_path: Path) -> None:
    workspace = _prepare_workspace(tmp_path)
    trusted = _merged_assets(TRUSTED, TRUSTED)
    row = _row("linuxbsd")
    _write_lock(workspace, {name: _sha(blob) for name, blob in trusted.items()})
    dist = workspace / "dist"
    dist.mkdir()
    installer = b"verified-installer\n"
    files = {"blazium-games_0.1.0_amd64.deb": installer}
    (dist / "blazium-games_0.1.0_amd64.deb").write_bytes(installer)
    (dist / "engine-provenance.json").write_text(
        json.dumps(_release_provenance(files, trusted[row["editor"]], trusted[row["template"]])) + "\n",
        encoding="utf-8",
    )
    _reset_publish_log()
    proc = _run_release(workspace)
    assert proc.returncode == 0, proc.stdout + proc.stderr
    assert REFUSAL not in proc.stdout + proc.stderr
    assert (dist / "launcher.json").is_file()
    assert "POST " in PUBLISH_LOG.read_text(encoding="utf-8")
