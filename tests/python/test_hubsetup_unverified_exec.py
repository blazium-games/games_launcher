"""The elevated Windows setup must not run a caller-chosen hub program.

Inno Setup reads /HUBSETUP= from the command line that survives the
administrator restart and, when that file exists, Exec's it from the elevated
process. A downloaded hub has to pass the publisher check in select_hub.ps1.
These tests fail while a path the caller picked is started without that check
holding for the bytes that actually start.

They pass when the parameter is ignored, or when a silent install never starts
a caller-chosen file and every other start is of bytes that passed the same
publisher check. Looking the path up again after the check still fails: a
writable file is replaced after a successful check returns.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from iss_install_model import (
    DiskFile,
    Outcome,
    elevated_setup_command,
    iter_params,
    param_constant,
    run_installer,
)

ROOT = Path(__file__).resolve().parents[2]
ISS = ROOT / "packaging" / "windows" / "blazium-games.iss"
SELECT_HUB = ROOT / "packaging" / "windows" / "select_hub.ps1"
SETUP = '"C:\\BlaziumLauncher-Setup.exe"'
PINNED = 'CN="Divine Games, inc."'


def _iss() -> str:
    return ISS.read_text(encoding="utf-8")


def _select_hub() -> str:
    return SELECT_HUB.read_text(encoding="utf-8")


def _file(content_id: str, status: str, subject: str) -> DiskFile:
    return DiskFile(content_id, status, subject, writable=True, provenance="caller")


def _unsigned(path: str) -> dict[str, DiskFile]:
    return {path: _file("unsigned-payload", "NotSigned", "")}


def _wrong(path: str) -> dict[str, DiskFile]:
    return {path: _file("wrong-publisher", "Valid", 'CN="Other Publisher"')}


def _pinned(path: str) -> dict[str, DiskFile]:
    return {path: _file("pinned-publisher", "Valid", PINNED)}


def _run(tail: str, files: dict[str, DiskFile], *, race: bool = False) -> Outcome:
    return run_installer(_iss(), _select_hub(), f"{SETUP} {tail}", files, race=race)


def _caller_launches(outcome: Outcome) -> list:
    return [item for item in outcome.launches if item.provenance == "caller"]


def _assert_caller_not_started(outcome: Outcome) -> None:
    launches = _caller_launches(outcome)
    assert launches == [], (
        "elevated setup started a caller-chosen program: "
        + ", ".join(repr(item) for item in launches)
    )
    caller_created = [path for path in outcome.created if _created_by_caller(outcome, path)]
    assert caller_created == [], (
        "setup wrote a caller-chosen program before it finished: " + ", ".join(caller_created)
    )
    assert outcome.deleted == [], (
        "setup deleted a file before it finished: " + ", ".join(outcome.deleted)
    )


def _created_by_caller(outcome: Outcome, path: str) -> bool:
    # VERSION and the installer's own files are not the caller's program.
    # run_installer records every SaveStringToFile; caller provenance is the signal.
    return "payload" in path.lower() or path.lower().endswith(".exe") and "blaziumlauncher-setup" not in path.lower() and "\\games\\" not in path.lower() and "hub.version" not in path.lower()


def test_param_reaches_the_elevated_setup_unchanged():
    """The command-line transformations themselves keep the caller path.

    This is the Inno Setup loader and respawn behavior, not the script. Removing
    the script parameter does not change this result.
    """
    tail = '/VERYSILENT /HUBSETUP="C:\\Users\\A B\\payload.exe"'
    elevated = elevated_setup_command(f"{SETUP} {tail}")
    assert param_constant(iter_params(elevated), "HUBSETUP") == "C:\\Users\\A B\\payload.exe"
    quiet = elevated_setup_command(f"{SETUP} /verysilent /hubsetup=\\\\server\\share\\payload.exe")
    params = iter_params(quiet)
    assert param_constant(params, "HUBSETUP") == "\\\\server\\share\\payload.exe"
    assert any(token.lower() == "/verysilent" for token in params)


def test_silent_install_does_not_start_a_caller_chosen_hub():
    path = "C:\\Users\\Public\\payload.exe"
    outcome = _run(f'/VERYSILENT /HUBSETUP="{path}"', _pinned(path))
    assert outcome.silent
    assert outcome.elevated_process
    assert outcome.hub_param == path
    _assert_caller_not_started(outcome)


def test_lowercase_silent_switch_does_not_start_a_caller_chosen_hub():
    path = "C:\\Users\\Public\\payload.exe"
    outcome = _run(f"/verysilent /hubsetup={path}", _pinned(path))
    assert outcome.silent
    _assert_caller_not_started(outcome)


def test_unsigned_hubsetup_is_not_started():
    path = "C:\\Users\\Public\\payload.exe"
    outcome = _run(f"/HUBSETUP={path}", _unsigned(path))
    assert not outcome.silent
    _assert_caller_not_started(outcome)


def test_wrong_publisher_hubsetup_is_not_started():
    path = "C:\\Users\\Public\\payload.exe"
    outcome = _run(f"/HUBSETUP={path}", _wrong(path))
    _assert_caller_not_started(outcome)


def test_quoted_path_with_spaces_is_not_started():
    path = "C:\\Users\\A B\\payload.exe"
    outcome = _run(f'/HUBSETUP="{path}"', _unsigned(path))
    assert outcome.hub_param == path
    _assert_caller_not_started(outcome)


def test_unc_hubsetup_is_not_started():
    path = "\\\\files\\share\\payload.exe"
    outcome = _run(f"/HUBSETUP={path}", _unsigned(path))
    assert outcome.hub_param == path
    _assert_caller_not_started(outcome)


def test_installhub_task_still_does_not_start_the_caller_file():
    path = "C:\\Users\\Public\\payload.exe"
    outcome = _run(f"/INSTALLHUB /HUBSETUP={path}", _unsigned(path))
    _assert_caller_not_started(outcome)


def test_check_then_exec_does_not_see_a_replaced_file():
    path = "C:\\Users\\Public\\payload.exe"
    outcome = _run(f"/HUBSETUP={path}", _pinned(path), race=True)
    launches = _caller_launches(outcome)
    assert launches == [] or all(
        item.verified and not item.writable_path and item.content_id == "pinned-publisher"
        for item in launches
    ), "setup started bytes that were not the pinned file it had checked: " + ", ".join(
        repr(item) for item in launches
    )
    assert all(item.content_id != "replaced-payload" for item in launches)
    assert outcome.deleted == []


def test_catalog_install_does_not_start_a_local_payload():
    """/INSTALLHUB without /HUBSETUP goes through select_hub.ps1, which cannot
    download here. That path must not invent a local program to run.
    """
    outcome = _run("/INSTALLHUB", {})
    _assert_caller_not_started(outcome)
