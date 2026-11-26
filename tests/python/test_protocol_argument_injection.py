"""Quoted blazium:// handler arguments must not choose the remote-control token.

The Windows installer registers the protocol handler as the launcher executable
plus the raw URL in quotes. These tests build that command line, split it the
way the shell and the launcher process do, and start the project with the
resulting arguments. They fail while a quote in the URL can make startup read
and write a control token at a path supplied on the command line.
"""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
ISS = ROOT / "packaging" / "windows" / "blazium-games.iss"
PROBE = "res://tests/protocol_argument_injection.gd"
PLACEHOLDER = "PLACEHOLDER_CONTROL_TOKEN"
INSTALL_EXE = r"C:\Program Files\Blazium\Games\BlaziumLauncher.exe"


def _godot_binary() -> Path:
    spec = importlib.util.spec_from_file_location(
        "run_godot_tests", ROOT / "ci" / "run_godot_tests.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module._godot_binary()


@pytest.fixture(scope="module")
def godot() -> Path:
    return _godot_binary()


def registered_open_command(executable: str) -> str:
    """The command string CurStepChanged writes for blazium\\shell\\open\\command."""
    text = ISS.read_text(encoding="utf-8")
    marker = "RegWriteStringValue(HKCR, 'blazium\\shell\\open\\command', '', "
    start = text.find(marker)
    assert start != -1, "protocol open command is not registered"
    body = text[start + len(marker) : text.find(");", start)]
    # The installer concatenates the quoted executable with a quoted %1.
    assert body == '\'"\' + ExpandConstant(\'{app}\\{#MyAppExeName}\') + \'" "%1"\''
    return f'"{executable}" "%1"'


def shell_argify(fmt: str, url: str) -> str:
    """Substitute %1 the way SHELL_ArgifyW does: the URL is inserted raw.

    Wine 9.0 dlls/shell32/shlexec.c SHELL_ArgifyW copies lpFile into the
    registry command for %1 and does not escape quotes. SearchPathW does not
    resolve a blazium:// URL, so the original string is the replacement.
    """
    out: list[str] = []
    index = 0
    while index < len(fmt):
        if fmt[index] != "%":
            out.append(fmt[index])
            index += 1
            continue
        index += 1
        if index >= len(fmt):
            break
        code = fmt[index]
        index += 1
        if code == "%":
            out.append("%")
        elif code == "1":
            out.append(url)
        else:
            raise AssertionError(f"registry command uses unsupported %{code}")
    return "".join(out)


def command_line_to_argv(cmdline: str) -> list[str]:
    """Split a Windows command line the way CommandLineToArgvW does.

    Port of Wine 9.0 dlls/shcore/main.c CommandLineToArgvW. Godot 4.3
    platform/windows/godot_windows.cpp passes this API's result to Main::setup.
    """
    if cmdline == "":
        return []
    length = len(cmdline)
    index = 0
    argv: list[str] = []

    if cmdline[index] == '"':
        index += 1
        buf: list[str] = []
        while index < length:
            if cmdline[index] == '"':
                index += 1
                break
            buf.append(cmdline[index])
            index += 1
        argv.append("".join(buf))
    else:
        start = index
        while index < length and cmdline[index] not in " \t":
            index += 1
        argv.append(cmdline[start:index])
        if index < length:
            index += 1

    while index < length and cmdline[index] in " \t":
        index += 1
    if index >= length:
        return argv

    current: list[str] = []
    quote_count = 0
    slash_count = 0
    while index < length:
        char = cmdline[index]
        if char in " \t" and quote_count == 0:
            argv.append("".join(current))
            current = []
            slash_count = 0
            index += 1
            while index < length and cmdline[index] in " \t":
                index += 1
            if index >= length:
                return argv
            continue
        if char == "\\":
            current.append(char)
            index += 1
            slash_count += 1
            continue
        if char == '"':
            if slash_count % 2 == 0:
                drop = slash_count // 2
                if drop:
                    del current[-drop:]
                quote_count += 1
            else:
                del current[-(slash_count // 2 + 1) :]
                current.append('"')
            index += 1
            slash_count = 0
            while index < length and cmdline[index] == '"':
                quote_count += 1
                if quote_count == 3:
                    current.append('"')
                    quote_count = 0
                index += 1
            if quote_count == 2:
                quote_count = 0
            continue
        current.append(char)
        index += 1
        slash_count = 0
    argv.append("".join(current))
    return argv


def handler_arguments(url: str) -> list[str]:
    """Arguments after argv[0], matching Godot's Main::setup(argv[0], argc - 1, &argv[1])."""
    command = shell_argify(registered_open_command(INSTALL_EXE), url)
    argv = command_line_to_argv(command)
    assert argv[0] == INSTALL_EXE
    return argv[1:]


def test_command_line_split_matches_the_documented_rules():
    """Parser self-check. This does not require the installer to stay vulnerable."""
    assert command_line_to_argv('prog "a b" c') == ["prog", "a b", "c"]
    assert command_line_to_argv(r'"C:\Program Files\app.exe"') == [r"C:\Program Files\app.exe"]
    template = f'"{INSTALL_EXE}" "%1"'
    quoted = 'blazium://library" --launcher-remote-path=/tmp/attacker/launcher_remote.json'
    argv = command_line_to_argv(shell_argify(template, quoted))
    assert argv[0] == INSTALL_EXE
    assert argv[1:] == [
        "blazium://library",
        "--launcher-remote-path=/tmp/attacker/launcher_remote.json",
    ]
    separated = 'blazium://library" -- --launcher-remote-path=/tmp/attacker/launcher_remote.json'
    assert command_line_to_argv(shell_argify(template, separated))[1:] == [
        "blazium://library",
        "--",
        "--launcher-remote-path=/tmp/attacker/launcher_remote.json",
    ]


def _seed(path: Path, body: bytes | None) -> None:
    if body is None:
        if path.exists():
            path.unlink()
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(body)


def _launch(godot: Path, home: Path, args: list[str], report: Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["HOME"] = str(home)
    env["APPDATA"] = ""
    env["USERPROFILE"] = str(home)
    env["PROBE_REPORT"] = str(report)
    # A private XDG config home keeps the default token file inside the test home.
    env["XDG_CONFIG_HOME"] = str(home / ".config")
    return subprocess.run(
        [
            str(godot),
            "--headless",
            "--path",
            str(ROOT),
            "--script",
            PROBE,
            *args,
        ],
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
        timeout=180,
    )


def _assert_path_not_adopted(
    godot: Path,
    tmp_path: Path,
    args: list[str],
    *,
    seed: bytes | None,
) -> None:
    home = tmp_path / "home"
    home.mkdir()
    target = tmp_path / "attacker" / "launcher_remote.json"
    _seed(target, seed)
    before = target.read_bytes() if seed is not None else None
    report = tmp_path / "probe.json"
    proc = _launch(godot, home, args, report)
    after = target.read_bytes() if target.exists() else None
    detail = f"exit={proc.returncode}"
    if seed is None:
        created = after is not None
        assert not created, "startup created a token file at the command-line path\n" + detail
    else:
        rewritten = after != before
        assert not rewritten, "startup rewrote the token file at the command-line path\n" + detail
    ran = report.is_file() or (home / ".config" / "blazium" / "launcher_remote.json").is_file()
    assert ran, "launcher startup did not run\n" + detail
    if report.is_file():
        payload = json.loads(report.read_text(encoding="utf-8"))
        adopted = payload.get("token_setting") == PLACEHOLDER
        assert not adopted, "launcher installed the control token from the command-line path\n" + detail


def test_quoted_protocol_url_does_not_create_a_token_file(godot: Path, tmp_path: Path):
    target = (tmp_path / "attacker" / "launcher_remote.json").as_posix()
    url = f'blazium://library" --launcher-remote-path={target}'
    _assert_path_not_adopted(godot, tmp_path, handler_arguments(url), seed=None)


def test_quoted_protocol_url_does_not_keep_an_existing_token(godot: Path, tmp_path: Path):
    target = (tmp_path / "attacker" / "launcher_remote.json").as_posix()
    url = f'blazium://library" --launcher-remote-path={target}'
    seed = json.dumps({"token": PLACEHOLDER}).encode("utf-8")
    _assert_path_not_adopted(godot, tmp_path, handler_arguments(url), seed=seed)


def test_user_argument_separator_does_not_select_a_token_path(godot: Path, tmp_path: Path):
    target = (tmp_path / "attacker" / "launcher_remote.json").as_posix()
    url = f'blazium://library" -- --launcher-remote-path={target}'
    seed = json.dumps({"token": PLACEHOLDER}).encode("utf-8")
    _assert_path_not_adopted(godot, tmp_path, handler_arguments(url), seed=seed)


def test_ensure_startup_does_not_write_a_command_line_token_path(godot: Path, tmp_path: Path):
    target = (tmp_path / "attacker" / "launcher_remote.json").as_posix()
    url = f'blazium://library" --ensure-launcher-remote --launcher-remote-path={target}'
    _assert_path_not_adopted(godot, tmp_path, handler_arguments(url), seed=None)


def test_plain_protocol_url_does_not_touch_an_unrelated_path(godot: Path, tmp_path: Path):
    _assert_path_not_adopted(godot, tmp_path, handler_arguments("blazium://library"), seed=None)


def test_direct_remote_path_argument_is_ignored(godot: Path, tmp_path: Path):
    """The same flag the quote produces, without depending on the registry text staying vulnerable."""
    target = (tmp_path / "attacker" / "launcher_remote.json").as_posix()
    seed = json.dumps({"token": PLACEHOLDER}).encode("utf-8")
    _assert_path_not_adopted(
        godot,
        tmp_path,
        ["--launcher-remote-path=" + target],
        seed=seed,
    )
