#!/usr/bin/env bash
# Claude / Codex / Grok / AGY / Copilot MCP client operations.
#
# Executed:
#   bash scripts/mcp-client.sh register <client|all> <http|sse|stdio>
#   bash scripts/mcp-client.sh config-check <client|all>
#
# `all` runs every client in parallel (see _mcp_client_all).
#
# Sourced (health-check):
#   resolve_token <ENV_VAR>  — process env, then launchctl getenv
#   MCP_CLIENTS              — every supported client, in display order

MCP_CLIENTS=(claude codex grok agy copilot)

source "$(dirname "${BASH_SOURCE[0]}")/spinner.sh"

resolve_token() {
  local var="$1"
  local token="${!var:-}"
  [[ -z "$token" ]] && token="$(launchctl getenv "$var" 2>/dev/null || true)"
  printf '%s\n' "$token"
}

agy_config_is_encrypted() {
  local config="$HOME/.gemini/config/mcp_config.json"
  [[ -f "$config" ]] && python3 -c \
    'import sys; sys.exit(open(sys.argv[1], "rb").read(10) != b"\0GITCRYPT\0")' \
    "$config"
}

_mcp_client_bin() {
  case "$1" in
    claude) printf '%s\n' "${CLAUDE:-claude}" ;;
    codex) printf '%s\n' "${CODEX:-codex}" ;;
    grok) printf '%s\n' "${GROK:-grok}" ;;
    agy) printf '%s\n' "${AGY:-agy}" ;;
    copilot) printf '%s\n' "${COPILOT:-copilot}" ;;
    *) echo "unknown client: $1" >&2; return 1 ;;
  esac
}

_mcp_client_title() {
  case "$1" in
    claude) echo Claude ;;
    codex) echo Codex ;;
    grok) echo Grok ;;
    agy) echo AGY ;;
    copilot) echo Copilot ;;
    *) return 1 ;;
  esac
}

_mcp_client_install_name() {
  case "$1" in
    claude) echo "Claude Code" ;;
    agy) echo "Antigravity CLI (agy)" ;;
    copilot) echo "GitHub Copilot CLI" ;;
    *) _mcp_client_title "$1" ;;
  esac
}

_mcp_client_defaults() {
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$script_dir/.." && pwd)}"
  START_SCRIPT="${START_SCRIPT:-$PROJECT_ROOT/scripts/start.sh}"
  HEADERS_HELPER="${HEADERS_HELPER:-$PROJECT_ROOT/scripts/mcp-auth-headers.sh}"
  MCP_NAME="${MCP_NAME:-telegram-mcp}"
  HTTP_URL="${HTTP_URL:-http://127.0.0.1:8765/mcp}"
  SSE_URL="${SSE_URL:-http://127.0.0.1:8765/sse}"
  CODEX_BEARER_ENV="${CODEX_BEARER_ENV:-TELEGRAM_MCP_TOKEN}"
  GROK_BEARER_ENV="${GROK_BEARER_ENV:-TELEGRAM_MCP_TOKEN}"
  AGY_BEARER_ENV="${AGY_BEARER_ENV:-TELEGRAM_MCP_TOKEN}"
  COPILOT_BEARER_ENV="${COPILOT_BEARER_ENV:-TELEGRAM_MCP_TOKEN}"
}

_mcp_client_remove() {
  local client="$1" bin="$2" name="$3"
  case "$client" in
    claude | grok) "$bin" mcp remove --scope user "$name" >/dev/null 2>&1 || true ;;
    codex | agy | copilot) "$bin" mcp remove "$name" >/dev/null 2>&1 || true ;;
  esac
}

_mcp_client_add() {
  local client="$1" transport="$2" bin="$3"
  case "$client:$transport" in
    claude:http)
      "$bin" mcp add-json --scope user "$MCP_NAME" \
        "{\"type\":\"http\",\"url\":\"$HTTP_URL\",\"headersHelper\":\"$HEADERS_HELPER\"}"
      ;;
    claude:sse)
      "$bin" mcp add-json --scope user "$MCP_NAME" \
        "{\"type\":\"sse\",\"url\":\"$SSE_URL\",\"headersHelper\":\"$HEADERS_HELPER\"}"
      ;;
    claude:stdio | grok:stdio)
      "$bin" mcp add --scope user "$MCP_NAME" -- "$START_SCRIPT" --transport stdio
      ;;
    codex:stdio | agy:stdio | copilot:stdio)
      "$bin" mcp add "$MCP_NAME" -- "$START_SCRIPT" --transport stdio
      ;;
    codex:http)
      "$bin" mcp add "$MCP_NAME" --url "$HTTP_URL" --bearer-token-env-var "$CODEX_BEARER_ENV"
      ;;
    # Grok, AGY and Copilot store the literal `${VAR}` and expand it when they
    # connect, so the token itself never lands in their config files.
    grok:http)
      "$bin" mcp add --scope user --transport http "$MCP_NAME" "$HTTP_URL" \
        --header "Authorization: Bearer \${${GROK_BEARER_ENV}}"
      ;;
    agy:http)
      "$bin" mcp add --type http \
        --header "Authorization: Bearer \${${AGY_BEARER_ENV}}" \
        "$MCP_NAME" "$HTTP_URL"
      ;;
    copilot:http)
      "$bin" mcp add --transport http \
        --header "Authorization: Bearer \${${COPILOT_BEARER_ENV}}" \
        "$MCP_NAME" "$HTTP_URL"
      ;;
    *:sse)
      echo "legacy SSE is only supported for Claude" >&2
      return 1
      ;;
    *)
      echo "unknown client/transport: $client $transport" >&2
      return 1
      ;;
  esac
}

_mcp_client_registering_line() {
  case "$1" in
    http) echo "Registering '$MCP_NAME' via Streamable HTTP at $HTTP_URL ..." ;;
    sse) echo "Registering '$MCP_NAME' via legacy SSE at $SSE_URL ..." ;;
    stdio) echo "Registering '$MCP_NAME' via stdio from $PROJECT_ROOT ..." ;;
    *) echo "unknown transport: $1" >&2; return 1 ;;
  esac
}

_mcp_client_success() {
  local client="$1" transport="$2" title as=""
  title="$(_mcp_client_title "$client")" || return 1
  case "$transport" in
    sse) as=" as legacy SSE" ;;
    stdio) as=" as stdio" ;;
  esac
  if [[ "$client:$transport" == codex:http ]]; then
    echo "Registered '$MCP_NAME' for Codex. Restart Codex after the launchd service is running."
  else
    echo "Registered '$MCP_NAME'$as for $title. Restart $(_mcp_client_install_name "$client") to apply the change."
  fi
}

_mcp_client_register() {
  local client="$1" transport="$2"
  local bin title
  _mcp_client_defaults
  bin="$(_mcp_client_bin "$client")"
  title="$(_mcp_client_title "$client")"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "$title CLI not found — skipping $title registration."
    echo "After installing $(_mcp_client_install_name "$client"), run 'make use-${transport}-${client}'."
    return 0
  fi
  if [[ "$client" == agy ]] && agy_config_is_encrypted; then
    echo "AGY config $HOME/.gemini/config/mcp_config.json is Git-crypt encrypted; run 'git -C \"\$HOME/.gemini\" crypt unlock', then 'make use-${transport}-agy'." >&2
    return 1
  fi
  echo "Removing existing '$MCP_NAME' $title MCP registration (if any)..."
  _mcp_client_remove "$client" "$bin" "$MCP_NAME"
  _mcp_client_registering_line "$transport"
  _mcp_client_add "$client" "$transport" "$bin"
  echo ""
  _mcp_client_success "$client" "$transport"
}

_mcp_client_config_check() {
  local client="$1"
  local bin title
  _mcp_client_defaults
  bin="$(_mcp_client_bin "$client")"
  title="$(_mcp_client_title "$client")"
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "$title CLI not found — $title is not configured. After installing it, run 'make use-http-${client}'."
    return 0
  fi
  case "$client" in
    claude | codex | copilot)
      "$bin" mcp get "$MCP_NAME" || echo "($MCP_NAME not yet registered with $title)"
      ;;
    grok | agy)
      "$bin" mcp list | grep -F "$MCP_NAME" || echo "($MCP_NAME not yet registered with $title)"
      ;;
  esac
}

# _mcp_client_all <label> <fn> [args...] — run <fn> <client> [args...] for every
# client at once. Each client CLI writes only its own config file, so the jobs
# share no state. Output goes to one file per client and is replayed in
# MCP_CLIENTS order, so the listing stays deterministic and a TUI-style CLI
# (claude) cannot redraw over lines printed before it. Fails if any job failed.
_mcp_client_all() {
  local label="$1" fn="$2" tmp client i status=0
  shift 2
  local -a pids=()
  tmp="$(mktemp -d)"
  for client in "${MCP_CLIENTS[@]}"; do
    "$fn" "$client" "$@" >"$tmp/$client" 2>&1 </dev/null &
    pids+=("$!")
  done
  spinner_start "$label"
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || status=1
  done
  spinner_stop
  for client in "${MCP_CLIENTS[@]}"; do
    cat "$tmp/$client"
  done
  rm -rf "$tmp"
  return "$status"
}

_mcp_client_main() {
  set -euo pipefail
  local cmd="${1:-}" client="${2:-}"
  shift || true
  case "$cmd:$client" in
    register:all)
      _mcp_client_all "Configuring MCP clients (${MCP_CLIENTS[*]})…" _mcp_client_register "${2:-}"
      ;;
    config-check:all)
      _mcp_client_all "Reading MCP client config (${MCP_CLIENTS[*]})…" _mcp_client_config_check
      ;;
    register:*)
      _mcp_client_register "$client" "${2:-}"
      ;;
    config-check:*)
      _mcp_client_config_check "$client"
      ;;
    *)
      local clients="${MCP_CLIENTS[*]}"
      echo "usage: $0 register <${clients// /|}|all> <http|sse|stdio>" >&2
      echo "       $0 config-check <${clients// /|}|all>" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _mcp_client_main "$@"
fi
