import os
import subprocess
import tempfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]

# client name -> Makefile variable holding its CLI, in scripts/mcp-client.sh order.
CLIENTS = {"claude": "CLAUDE", "codex": "CODEX", "grok": "GROK", "agy": "AGY", "copilot": "COPILOT"}
TITLES = {"claude": "Claude", "codex": "Codex", "grok": "Grok", "agy": "AGY", "copilot": "Copilot"}

# Every single-client registration target; SSE is Claude-only.
REGISTER_TARGETS = [
    *((f"use-{transport}-{client}", variable) for transport in ("http", "stdio") for client, variable in CLIENTS.items()),
    ("use-sse-claude", "CLAUDE"),
]


def run_make(target: str, **variables: str) -> subprocess.CompletedProcess[str]:
    with tempfile.TemporaryDirectory() as home:
        return subprocess.run(
            ["make", target, *(f"{key}={value}" for key, value in variables.items())],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
            env={**os.environ, "HOME": home},
        )


@pytest.mark.parametrize("target,variable", REGISTER_TARGETS)
def test_missing_client_is_skipped_with_follow_up(target, variable):
    result = run_make(target, **{variable: "definitely-missing-mcp-cli"})

    assert result.returncode == 0
    assert "CLI not found" in result.stdout
    assert f"make {target}" in result.stdout


@pytest.mark.parametrize("target,variable", REGISTER_TARGETS)
def test_client_registration_failure_is_not_reported_as_success(target, variable):
    result = run_make(target, **{variable: "false"})

    assert result.returncode != 0
    assert "Registered 'telegram-mcp'" not in result.stdout


@pytest.mark.parametrize("registered", CLIENTS)
def test_http_clients_are_handled_independently(registered):
    # Stub every client, so the parallel run never touches a real installed CLI.
    variables = {
        variable: "true" if client == registered else f"definitely-missing-{client}"
        for client, variable in CLIENTS.items()
    }
    result = run_make("use-http", **variables)

    assert result.returncode == 0
    assert f"Registered 'telegram-mcp' for {TITLES[registered]}" in result.stdout
    for client in CLIENTS:
        if client != registered:
            assert f"{TITLES[client]} CLI not found" in result.stdout


def test_parallel_use_http_output_keeps_client_order():
    variables = {variable: "true" for variable in CLIENTS.values()}
    result = run_make("use-http", **variables)

    assert result.returncode == 0
    positions = [result.stdout.index(f"for {TITLES[client]}.") for client in CLIENTS]
    assert positions == sorted(positions)


def test_parallel_use_http_fails_when_any_client_fails():
    variables = {variable: "true" for variable in CLIENTS.values()}
    variables["GROK"] = "false"
    result = run_make("use-http", **variables)

    assert result.returncode != 0
    assert "Registered 'telegram-mcp' for Claude" in result.stdout
    assert "Registered 'telegram-mcp' for Grok" not in result.stdout


@pytest.mark.parametrize("client", CLIENTS)
def test_health_skips_missing_client_cli(client):
    result = run_make("health", **{CLIENTS[client]: f"definitely-missing-{client}"})

    assert f"{client} CLI not found" in result.stdout
