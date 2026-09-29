import os
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
CLIENT_SCRIPT = ROOT / "scripts" / "mcp-client.sh"


def run_client(*args: str, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    if extra_env:
        env.update(extra_env)
    return subprocess.run(
        ["bash", str(CLIENT_SCRIPT), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


def source_resolve_token(var: str, extra_env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(extra_env)
    return subprocess.run(
        ["bash", "-c", f'source "{CLIENT_SCRIPT}" && resolve_token "{var}"'],
        cwd=ROOT,
        capture_output=True,
        text=True,
        check=False,
        env=env,
    )


CLIENTS = [("claude", "CLAUDE"), ("codex", "CODEX"), ("grok", "GROK"), ("agy", "AGY"), ("copilot", "COPILOT")]


@pytest.mark.parametrize("client,variable", CLIENTS)
def test_register_missing_cli_is_skipped_with_follow_up(client, variable):
    result = run_client("register", client, "http", extra_env={variable: "definitely-missing-mcp-cli"})

    assert result.returncode == 0
    assert "CLI not found" in result.stdout
    assert f"make use-http-{client}" in result.stdout
    assert "Registered" not in result.stdout


@pytest.mark.parametrize("client,variable", CLIENTS)
def test_register_failure_is_not_reported_as_success(client, variable, tmp_path):
    result = run_client("register", client, "http", extra_env={variable: "false", "HOME": str(tmp_path)})

    assert result.returncode != 0
    assert "Removing existing" in result.stdout
    assert "Registered 'telegram-mcp'" not in result.stdout


def test_copilot_http_header_keeps_token_as_env_reference(tmp_path):
    # A fake copilot that records its `mcp add` arguments.
    log = tmp_path / "args"
    copilot = tmp_path / "copilot"
    copilot.write_text(f'#!/bin/sh\n[ "$2" = add ] && printf "%s\\n" "$@" > "{log}"\nexit 0\n')
    copilot.chmod(copilot.stat().st_mode | stat.S_IEXEC)

    result = run_client("register", "copilot", "http", extra_env={"COPILOT": str(copilot)})

    assert result.returncode == 0
    args = log.read_text().splitlines()
    assert "Authorization: Bearer ${TELEGRAM_MCP_TOKEN}" in args
    assert args[-2:] == ["telegram-mcp", "http://127.0.0.1:8765/mcp"]


def test_agy_registration_stops_before_cli_when_config_is_encrypted(tmp_path):
    config = tmp_path / ".gemini" / "config" / "mcp_config.json"
    config.parent.mkdir(parents=True)
    config.write_bytes(b"\x00GITCRYPT\x00encrypted")
    log = tmp_path / "agy-calls"
    agy = tmp_path / "agy"
    agy.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" >> "{log}"\n')
    agy.chmod(agy.stat().st_mode | stat.S_IEXEC)

    result = run_client("register", "agy", "http", extra_env={"HOME": str(tmp_path), "AGY": str(agy)})

    assert result.returncode != 0
    assert "Git-crypt encrypted" in result.stderr
    assert not log.exists()


def test_resolve_token_prefers_process_env(tmp_path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    launchctl = fake_bin / "launchctl"
    launchctl.write_text("#!/bin/sh\necho from-launchctl\n")
    launchctl.chmod(launchctl.stat().st_mode | stat.S_IEXEC)

    result = source_resolve_token(
        "TELEGRAM_MCP_TOKEN",
        {
            "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
            "TELEGRAM_MCP_TOKEN": "from-env",
        },
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "from-env"


def test_resolve_token_falls_back_to_launchctl(tmp_path):
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    launchctl = fake_bin / "launchctl"
    launchctl.write_text('#!/bin/sh\n[ "$1" = getenv ] && echo from-launchctl\n')
    launchctl.chmod(launchctl.stat().st_mode | stat.S_IEXEC)

    result = source_resolve_token(
        "TELEGRAM_MCP_TOKEN",
        {
            "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
            "TELEGRAM_MCP_TOKEN": "",
        },
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "from-launchctl"
