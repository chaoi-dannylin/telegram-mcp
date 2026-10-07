#!/usr/bin/env bash
# One-shot health check for the telegram-mcp server across all seven layers
# (the client layers 3-7 run in parallel):
#   1. launchd  — is the background service loaded *and running*?
#   2. server   — is the HTTP port listening? (401 is healthy: auth is enforced)
#   3. claude   — is Claude's MCP registration actually connecting?
#   4. codex    — is Codex's MCP registration enabled *and* does the bearer token it
#                 points at actually complete an MCP handshake? The Codex CLI has no
#                 connection probe (a dead URL still lists as "enabled"), so we run one
#                 ourselves: resolve the token from the env var Codex reads, then POST
#                 `initialize`. 200 = token accepted, 401 = Codex would be rejected.
#   5. grok     — is Grok's MCP registration actually connecting? `grok mcp doctor`
#                 handshakes. Grok expands `${TELEGRAM_MCP_TOKEN}` in the registered
#                 Authorization header, so this probe publishes that env var the same
#                 way a Grok session started after `make use-http-grok` would.
#   6. agy      — is AGY's MCP registration actually connecting? AGY stores
#                 `${TELEGRAM_MCP_TOKEN}` in its config and expands it at runtime;
#                 we probe the same way as Codex: resolve the token, then POST
#                 `initialize` to confirm the handshake.
#   7. copilot  — is Copilot's MCP registration enabled and does its token work?
#                 Copilot also expands `${TELEGRAM_MCP_TOKEN}` at connect time and
#                 has no probe, so it gets the same handshake as AGY.
#
# Read-only: never changes config. Exits 0 when every layer is healthy,
# 1 otherwise, so it can gate other commands (`make health && ...`).
#
# Usage:
#   bash scripts/health-check.sh        # or: make health
#
# Overridable via env; otherwise read from .env, else the built-in defaults:
#   MCP_HOST=127.0.0.1 MCP_PORT=8765 MCP_NAME=telegram-mcp

# NOTE: deliberately no `-e` — every layer must be reported even when an
# earlier one fails. Failures are collected in $fail instead.
set -uo pipefail

# MCP_HOST / MCP_PORT / MCP_URL from env, then .env, then defaults.
_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_script_dir/mcp-endpoint.sh"
source "$_script_dir/mcp-client.sh"

MCP_NAME="${MCP_NAME:-telegram-mcp}"
CLAUDE="${CLAUDE:-claude}"
CODEX="${CODEX:-codex}"
GROK="${GROK:-grok}"
AGY="${AGY:-agy}"
COPILOT="${COPILOT:-copilot}"
LAUNCHD_LABEL="com.telegram-mcp.server"
LOG_ERR="$HOME/Library/Logs/telegram-mcp/server.err.log"

fail=0

# Result markers. ok/bad carry the pass/fail verdict for a layer (bad also flags the
# run); skip is for a layer that legitimately does not apply, e.g. an uninstalled CLI.
ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; fail=1; }
skip() { echo "  ⏭️  $*"; }

# 1. launchd — exact label match on column 3; column 1 is the PID ("-" when the
#    job is registered but not running, e.g. crash-looping). Same parse as setup.sh.
echo "launchd:"
launchd_line="$(launchctl list 2>/dev/null | awk -v label="$LAUNCHD_LABEL" '$3 == label')"
if [[ -z "$launchd_line" ]]; then
  bad "NOT loaded — run scripts/install-launchd.sh"
else
  launchd_pid="$(awk '{print $1}' <<<"$launchd_line")"
  if [[ "$launchd_pid" =~ ^[0-9]+$ ]]; then
    ok "running (PID $launchd_pid, $LAUNCHD_LABEL)"
  else
    bad "loaded but NOT running — check $LOG_ERR"
  fi
fi

# 2. server — curl's -w already prints 000 on connection failure, so no `|| echo`.
echo "server :"
code="$(curl -sS -o /dev/null -w '%{http_code}' -m 5 -X POST \
  -H 'Content-Type: application/json' -d '{}' "$MCP_URL" 2>/dev/null)"
case "${code:-000}" in
  401) ok  "HTTP 401 — up (auth enforced, healthy)";;
  200) ok  "HTTP 200 — up";;
  000) bad "unreachable — server not listening on $MCP_HOST:$MCP_PORT";;
  *)   bad "HTTP $code — up but unexpected status";;
esac

# 3+. clients — each layer checks one client's own registration and connection.
#     A missing CLI is skipped, not failed (single-client setups are normal).

# probe_token <env var> <ok detail> — POST `initialize` with the token a client
# reads from <env var>, the way that client would, and report the verdict. For
# clients whose CLI has no connection probe of its own (a dead URL still lists
# as registered). The token is never echoed.
probe_token() {
  local var="$1" detail="$2" token code
  token="$(resolve_token "$var")"
  if [[ -z "$token" ]]; then
    bad "registered but \$$var is unset — restart the service"
    return
  fi
  code="$(curl -sS -o /dev/null -w '%{http_code}' -m 5 -X POST \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -H "Authorization: Bearer $token" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"health-check","version":"0"}}}' \
    "$MCP_URL" 2>/dev/null)"
  case "${code:-000}" in
    200) ok  "handshake OK ($detail)";;
    401) bad "the token in \$$var was REJECTED (HTTP 401)";;
    000) bad "server unreachable at $MCP_HOST:$MCP_PORT";;
    *)   bad "handshake returned HTTP $code";;
  esac
}

# claude — `claude mcp get` connects for real, so its status line is the verdict.
check_claude() {
  local mcp_get issue
  if ! mcp_get="$("$CLAUDE" mcp get "$MCP_NAME" 2>/dev/null)" || [[ -z "$mcp_get" ]]; then
    bad "$MCP_NAME not registered — run 'make use-http-claude'"
  elif grep -q 'Connected' <<<"$mcp_get"; then
    ok "connected (Claude's own registration)"
  else
    # `claude mcp get` reports the reason on an "Issue:" line; fall through to the raw
    # status text if the format ever changes.
    issue="$(sed -n 's/^[[:space:]]*Issue:[[:space:]]*//p' <<<"$mcp_get" | head -1)"
    bad "NOT connected — ${issue:-$(grep -E 'Status' <<<"$mcp_get" | head -1 | sed 's/^[[:space:]]*//')}"
  fi
}

# codex — `codex mcp get` reports config only, so probe with the token from the
# env var Codex is configured to read. Both lookups in resolve_token are paths
# Codex itself uses: launcher.sh publishes the token via `launchctl setenv` (what
# a GUI-launched Codex inherits); a shell-started Codex inherits the shell's value.
check_codex() {
  local codex_get transport var
  if ! codex_get="$("$CODEX" mcp get "$MCP_NAME" 2>/dev/null)" || [[ -z "$codex_get" ]]; then
    bad "$MCP_NAME not registered — run 'make use-http-codex'"
    return
  fi
  if ! grep -qE '^[[:space:]]*enabled:[[:space:]]*true' <<<"$codex_get"; then
    bad "registered but DISABLED — run 'make use-http-codex'"
    return
  fi
  transport="$(awk '/^[[:space:]]*transport:/{print $2; exit}' <<<"$codex_get")"
  var="$(awk '/^[[:space:]]*bearer_token_env_var:/{print $2; exit}' <<<"$codex_get")"
  if [[ -z "$var" || "$var" == "-" ]]; then
    bad "enabled ($transport) but no bearer_token_env_var — run 'make use-http-codex'"
  else
    probe_token "$var" "$transport, token from \$$var"
  fi
}

# grok — `grok mcp doctor` handshakes itself. Grok expands `${TELEGRAM_MCP_TOKEN}`
# in the registered header, so publish that var the way a Grok session started
# after `make use-http-grok` would see it.
check_grok() {
  local grok_out
  grok_out="$(TELEGRAM_MCP_TOKEN="$(resolve_token TELEGRAM_MCP_TOKEN)" \
    "$GROK" mcp doctor "$MCP_NAME" --json 2>/dev/null)" || true
  if [[ -z "$grok_out" || "$grok_out" == *"not found"* ]]; then
    bad "$MCP_NAME not registered — run 'make use-http-grok'"
  elif [[ "$grok_out" == *'"healthy": true'* ]]; then
    ok "connected (Grok's own registration)"
  elif [[ "$grok_out" == *"401"* ]]; then
    bad "NOT connected — HTTP 401. Run 'make use-http-grok' so Grok sends \$TELEGRAM_MCP_TOKEN"
  else
    bad "NOT connected — run 'make use-http-grok'"
  fi
}

# agy — stores `${TELEGRAM_MCP_TOKEN}` in mcp_config.json and expands it at
# load time; its CLI has no probe, so handshake with that token ourselves.
check_agy() {
  if agy_config_is_encrypted; then
    bad "AGY config is Git-crypt encrypted — run 'git -C \"\$HOME/.gemini\" crypt unlock', then 'make use-http-agy'"
  elif ! "$AGY" mcp list 2>/dev/null | grep -qF "$MCP_NAME"; then
    bad "$MCP_NAME not registered — run 'make use-http-agy'"
  else
    probe_token TELEGRAM_MCP_TOKEN "token from \$TELEGRAM_MCP_TOKEN"
  fi
}

# copilot — same model as AGY: `${TELEGRAM_MCP_TOKEN}` stays literal in
# ~/.copilot/mcp-config.json and is expanded on connect; `copilot mcp get` has
# no probe, so handshake with that token ourselves.
check_copilot() {
  local copilot_get
  if ! copilot_get="$("$COPILOT" mcp get "$MCP_NAME" 2>/dev/null)"; then
    bad "$MCP_NAME not registered — run 'make use-http-copilot'"
  elif grep -qE '^[[:space:]]*Status:[[:space:]]*Disabled' <<<"$copilot_get"; then
    bad "registered but DISABLED — run 'copilot mcp enable $MCP_NAME'"
  else
    probe_token TELEGRAM_MCP_TOKEN "token from \$TELEGRAM_MCP_TOKEN"
  fi
}

# The client layers are independent read-only probes, so run them all at once
# and print each block in MCP_CLIENTS order. Each runs in a subshell with its
# own `fail`, reported back through the exit status.
_tmp="$(mktemp -d)"
_pids=()
for _client in "${MCP_CLIENTS[@]}"; do
  (
    fail=0
    _upper="$(tr '[:lower:]' '[:upper:]' <<<"$_client")"
    _bin="${!_upper:-$_client}"
    printf '%-7s:\n' "$_client"
    if ! command -v "$_bin" >/dev/null 2>&1; then
      skip "$_client CLI not found"
    else
      "check_$_client"
    fi
    exit "$fail"
  ) >"$_tmp/$_client" 2>&1 </dev/null &
  _pids+=("$!")
done
spinner_start "Checking MCP clients (${MCP_CLIENTS[*]})…"
for _pid in "${_pids[@]}"; do
  wait "$_pid" || fail=1
done
spinner_stop
for _client in "${MCP_CLIENTS[@]}"; do
  cat "$_tmp/$_client"
done
rm -rf "$_tmp"

echo
if [[ "$fail" -eq 0 ]]; then
  echo "✅ healthy"
else
  echo "❌ problems found — see above"
fi
exit "$fail"
