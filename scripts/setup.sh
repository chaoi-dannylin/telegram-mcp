#!/usr/bin/env bash
# One-shot setup: prerequisites → credentials → Keychain → launchd → MCP clients
#
# Usage:
#   bash scripts/setup.sh
#
# What this script handles automatically:
#   - Installs uv if missing
#   - Prompts for Telegram API ID, API Hash, and phone verification (session string)
#   - Stores all credentials in macOS Keychain
#   - Configures a dedicated allowed root for local file tools
#   - Installs and starts the launchd Streamable HTTP server
#   - Registers each installed Claude Code / Codex / Grok / AGY / Copilot client for authenticated Streamable HTTP
#
# Required user input (interactive prompts):
#   - Telegram API ID and API Hash (from https://my.telegram.org/apps)
#   - Phone number and Telegram verification code (for session string generation)
#   - Choose "store in Keychain" when the generator asks

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
# MCP_CLIENTS and the spinner (mcp-client.sh sources spinner.sh).
source "$SCRIPT_DIR/mcp-client.sh"

_kc_get() { security find-generic-password -a "$USER" -s "$1" -w 2>/dev/null || true; }
_kc_set() {
  security delete-generic-password -a "$USER" -s "$1" 2>/dev/null || true
  security add-generic-password -a "$USER" -s "$1" -w "$2"
}

echo "=== Telegram MCP 快速設定 ==="
echo

# ── Prerequisites ─────────────────────────────────────────────────────────────

echo "前置需求檢查…"

# Xcode Command Line Tools (provides git, python3, security)
if ! xcode-select -p &>/dev/null; then
  echo "  安裝 Xcode Command Line Tools（需要管理員密碼）…"
  xcode-select --install
  echo "  ⚠️  安裝視窗已開啟，完成後請重新執行本 script"
  exit 0
fi

# uv
# The Astral installer drops uv in ~/.local/bin, which a non-login shell may not
# have on PATH yet — add it before probing so an existing install is found.
export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"

if ! command -v curl &>/dev/null; then
  echo "  ❌ curl 未找到，macOS 應內建 curl，請確認系統環境"
  exit 1
fi

if ! command -v uv &>/dev/null; then
  echo "  安裝 uv…"
  # Prefer the Astral installer: it ships prebuilt binaries. Homebrew is a
  # fallback because a prefix without bottles for this macOS/arch (e.g. a
  # Rosetta /usr/local brew) builds rust and llvm from source for hours.
  if ! curl -LsSf https://astral.sh/uv/install.sh | sh; then
    if command -v brew &>/dev/null; then
      brew install uv
    else
      echo "  ❌ uv 安裝失敗，且找不到 Homebrew 可作為備援"
      exit 1
    fi
  fi
  hash -r
  if ! command -v uv &>/dev/null; then
    echo "  ❌ uv installer 執行完成，但仍找不到 uv"
    exit 1
  fi
  echo "  ✅ uv 已安裝 ($(uv --version))"
else
  echo "  ✅ uv $(uv --version)"
fi

echo

# ── Step 1: API credentials ───────────────────────────────────────────────────

echo "步驟 1：Telegram API 憑證（從 https://my.telegram.org/apps 取得）"

EXISTING_ID="$(_kc_get telegram-api-id)"
EXISTING_HASH="$(_kc_get telegram-api-hash)"

if [[ -n "$EXISTING_ID" && -n "$EXISTING_HASH" ]]; then
  echo "  Keychain 已有憑證 (api_id=${EXISTING_ID:0:4}…)，是否重新輸入？[y/N]"
  read -rp "  > " REDO_CREDS
  if [[ "$REDO_CREDS" =~ ^[Yy]$ ]]; then
    EXISTING_ID=""
    EXISTING_HASH=""
  fi
fi

if [[ -z "$EXISTING_ID" ]]; then
  read -rp "  API ID: " API_ID
  read -rp "  API Hash: " API_HASH
  _kc_set "telegram-api-id" "$API_ID"
  _kc_set "telegram-api-hash" "$API_HASH"
  echo "  ✅ 憑證已存入 Keychain"
else
  API_ID="$EXISTING_ID"
  API_HASH="$EXISTING_HASH"
  echo "  ✅ 沿用 Keychain 中的憑證"
fi
echo

# ── Step 2: Session string ────────────────────────────────────────────────────

echo "步驟 2：Session String"

EXISTING_SESSION="$(_kc_get telegram-session-string)"
if [[ -n "$EXISTING_SESSION" ]]; then
  echo "  Keychain 已有 session string，是否重新產生？[y/N]"
  read -rp "  > " REDO_SESSION
  if [[ ! "$REDO_SESSION" =~ ^[Yy]$ ]]; then
    echo "  ✅ 沿用 Keychain 中的 session string"
    echo
    SKIP_SESSION=1
  fi
fi

if [[ -z "${SKIP_SESSION:-}" ]]; then
  TELEGRAM_API_ID="$API_ID" \
  TELEGRAM_API_HASH="$API_HASH" \
    uv --directory "$PROJECT_DIR" run telegram-mcp-generate-session
fi
echo

# ── Step 3: launchd service ───────────────────────────────────────────────────

echo "步驟 3：安裝 Streamable HTTP launchd 常駐服務…"

# Stateless Streamable HTTP cannot request MCP Roots from the client. Give it
# narrow exchange roots instead of exposing the user's home or workspace.
ROOTS_FILE="$HOME/Library/Application Support/telegram-mcp/allowed-roots"
if [[ -z "${TELEGRAM_MCP_ALLOWED_ROOTS+set}" ]]; then
  DEFAULT_ALLOWED_ROOT="$HOME/Downloads/telegram_mcp_files"
  mkdir -p "$DEFAULT_ALLOWED_ROOT"
  if [[ -s "$ROOTS_FILE" ]]; then
    TELEGRAM_MCP_ALLOWED_ROOTS="$(awk 'NF { printf "%s%s", separator, $0; separator="," }' "$ROOTS_FILE")"
  else
    TELEGRAM_MCP_ALLOWED_ROOTS="$DEFAULT_ALLOWED_ROOT"
  fi
  if ! tr ',' '\n' <<<"$TELEGRAM_MCP_ALLOWED_ROOTS" | grep -Fqx "$DEFAULT_ALLOWED_ROOT"; then
    TELEGRAM_MCP_ALLOWED_ROOTS="$TELEGRAM_MCP_ALLOWED_ROOTS,$DEFAULT_ALLOWED_ROOT"
  fi

  # telegram-summary writes attachments below docs/chat/. Detect either an
  # embedded telegram-mcp checkout or an explicitly configured project root,
  # then grant only docs/chat rather than the repository that contains it.
  SUMMARY_PROJECT_ROOT="$(git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ ! -f "$SUMMARY_PROJECT_ROOT/.claude/commands/telegram-summary.md" && -n "${TELEGRAM_MCP_SUMMARY_PROJECT:-}" ]]; then
    SUMMARY_PROJECT_ROOT="$TELEGRAM_MCP_SUMMARY_PROJECT"
  fi
  if [[ -f "$SUMMARY_PROJECT_ROOT/.claude/commands/telegram-summary.md" ]]; then
    SUMMARY_CHAT_ROOT="$SUMMARY_PROJECT_ROOT/docs/chat"
    mkdir -p "$SUMMARY_CHAT_ROOT"
    if ! tr ',' '\n' <<<"$TELEGRAM_MCP_ALLOWED_ROOTS" | grep -Fqx "$SUMMARY_CHAT_ROOT"; then
      TELEGRAM_MCP_ALLOWED_ROOTS="$TELEGRAM_MCP_ALLOWED_ROOTS,$SUMMARY_CHAT_ROOT"
    fi
  fi

  export TELEGRAM_MCP_ALLOWED_ROOTS
  echo "  ✅ 檔案工具 allowed roots："
  tr ',' '\n' <<<"$TELEGRAM_MCP_ALLOWED_ROOTS" | sed 's/^/      /'
elif [[ -n "${TELEGRAM_MCP_ALLOWED_ROOTS:-}" ]]; then
  echo "  ✅ 使用 TELEGRAM_MCP_ALLOWED_ROOTS 指定的目錄"
else
  echo "  ℹ️  明確停用檔案工具（TELEGRAM_MCP_ALLOWED_ROOTS 為空）"
fi
bash "$SCRIPT_DIR/install-launchd.sh"
echo

# ── Step 4: MCP clients ──────────────────────────────────────────────────────

echo "步驟 4：確認已安裝的 Claude Code / Codex / Grok / AGY / Copilot MCP 設定…"
make -C "$PROJECT_DIR" --no-print-directory config-check
echo

# Optional flag: clean up project-level telegram-mcp overrides
if [[ "${1:-}" == "--clean-project-overrides" ]]; then
  echo "清理專案層級 telegram-mcp 覆蓋…"
  CLAUDE_JSON="$HOME/.claude.json"
  python3 - "$CLAUDE_JSON" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    d = json.load(f)
removed = []
for proj, val in d.get("projects", {}).items():
    if "telegram-mcp" in val.get("mcpServers", {}):
        del val["mcpServers"]["telegram-mcp"]
        removed.append(proj)
if removed:
    with open(path, "w") as f:
        json.dump(d, f, indent=2, ensure_ascii=False)
    print(f"  ✅ 已移除 {len(removed)} 個專案覆蓋")
    for p in removed:
        print(f"       - {p}")
else:
    print("  ✅ 沒有專案覆蓋需要清理")
PYEOF
  echo
fi

# ── Step 5: Clean up stale stdio processes ────────────────────────────────────
# After switching to HTTP, pre-existing stdio telegram-mcp processes (spawned by
# Claude Code before the config change) become orphans. Since the new config
# points to HTTP, these won't be respawned after we kill them.

echo "步驟 5：清理舊的 stdio zombie 進程…"

ZOMBIES=$(ps -axo pid,command | awk '$NF == "telegram-mcp" {print $1}')
if [[ -n "$ZOMBIES" ]]; then
  COUNT=$(echo "$ZOMBIES" | wc -l | tr -d ' ')
  echo "$ZOMBIES" | xargs kill 2>/dev/null || true
  echo "  ✅ 已清理 $COUNT 個 zombie 進程"
else
  echo "  ✅ 無 zombie 進程"
fi
echo

# ── Step 6: Verify Streamable HTTP server ─────────────────────────────────────

echo "步驟 6：驗證 Streamable HTTP server…"

# MCP_HOST / MCP_PORT / MCP_URL from env, then .env, then defaults — the same
# resolution install-launchd.sh uses, so this always probes the real port.
source "$SCRIPT_DIR/mcp-endpoint.sh"
LOG_ERR="$HOME/Library/Logs/telegram-mcp/server.err.log"
VERIFY_OK=1

# 6a. launchd 是否註冊
LAUNCHD_LINE="$(launchctl list | awk '$3 == "com.telegram-mcp.server"' || true)"
if [[ -z "$LAUNCHD_LINE" ]]; then
  echo "  ❌ launchd 服務未註冊，請重新執行 install-launchd.sh"
  VERIFY_OK=0
else
  echo "  ✅ launchd 服務已註冊"
fi

# 6b. port 是否真的在監聽（服務可能註冊成功卻不斷崩潰重啟）
if [[ "$VERIFY_OK" == 1 ]]; then
  PORT_UP=0
  spinner_start "  等待 Port $MCP_PORT 監聽（最多 20 秒）…"
  for _ in $(seq 1 40); do
    if nc -z "$MCP_HOST" "$MCP_PORT" 2>/dev/null; then PORT_UP=1; break; fi
    sleep 0.5
  done
  spinner_stop
  if [[ "$PORT_UP" == 1 ]]; then
    echo "  ✅ Port $MCP_PORT 監聽中"
    LAUNCHD_LINE="$(launchctl list | awk '$3 == "com.telegram-mcp.server"' || true)"
    SERVICE_PID="$(awk '{print $1}' <<<"$LAUNCHD_LINE")"
    if [[ "$SERVICE_PID" =~ ^[0-9]+$ ]]; then
      echo "  ✅ launchd 服務已啟動 (PID $SERVICE_PID)"
    else
      echo "  ❌ Port $MCP_PORT 有服務，但不是執行中的 launchd 服務"
      VERIFY_OK=0
    fi
  else
    echo "  ❌ Port $MCP_PORT 在 20 秒內沒有起來"
    VERIFY_OK=0
  fi
fi

# 6c. 認證與 MCP 交握
if [[ "$VERIFY_OK" == 1 ]]; then
  MCP_TOKEN="$(_kc_get telegram-mcp-token)"
  if [[ -z "$MCP_TOKEN" ]]; then
    echo "  ❌ Keychain 找不到 telegram-mcp-token，請重新執行 install-launchd.sh"
    VERIFY_OK=0
  else
    INIT_BODY='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"setup.sh","version":"1"}}}'

    CODE_NOAUTH="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$MCP_URL" \
      -X POST -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' -d "$INIT_BODY" || true)"
    if [[ "$CODE_NOAUTH" == "401" ]]; then
      echo "  ✅ 未帶 token 正確回傳 401"
    else
      echo "  ❌ 未帶 token 預期 401，實際收到 $CODE_NOAUTH"
      VERIFY_OK=0
    fi

    INIT_RESP="$(curl -s --max-time 15 "$MCP_URL" -X POST \
      -H "Authorization: Bearer $MCP_TOKEN" -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' -d "$INIT_BODY" || true)"
    if grep -q '"serverInfo"' <<<"$INIT_RESP"; then
      SERVER_INFO="$(sed -n 's/.*"serverInfo":{"name":"\([^"]*\)","version":"\([^"]*\)".*/\1 v\2/p' <<<"$INIT_RESP")"
      echo "  ✅ MCP 交握成功${SERVER_INFO:+（${SERVER_INFO}）}"
    else
      echo "  ❌ MCP 交握失敗（帶 token 仍無法取得 serverInfo）"
      VERIFY_OK=0
    fi
  fi
fi

# 6d. file-path tools 是否有 server-side roots
if [[ -s "$ROOTS_FILE" ]]; then
  echo "  ✅ 檔案工具 allowed roots："
  sed 's/^/      /' "$ROOTS_FILE"
else
  echo "  ⚠️  未設定 allowed roots；download_media、send_file 等檔案工具已停用"
fi

# 6e. 失敗時給出可行動的診斷
if [[ "$VERIFY_OK" != 1 ]]; then
  echo
  echo "  ── 診斷 ──"
  if [[ -z "$(_kc_get telegram-session-string)" ]]; then
    SESSION_LABELS="$(_kc_get telegram-session-labels)"
    if [[ -n "$SESSION_LABELS" ]]; then
      echo "  ⚠️  Keychain 只有帶 label 的 session（${SESSION_LABELS}），"
      echo "      但服務讀取的是無 label 的 telegram-session-string。"
      echo "      請重跑步驟 2，並在 Account label 那題直接按 Enter 留空。"
    else
      echo "  ⚠️  Keychain 沒有 telegram-session-string。"
      echo "      請重跑步驟 2，並在最後一題輸入 y 存入 Keychain。"
    fi
  fi
  if [[ -f "$LOG_ERR" ]]; then
    echo "  最近的錯誤訊息（${LOG_ERR}）："
    { grep -v "IncompleteFieldDefinitionWarning\|warnings.warn" "$LOG_ERR" | tail -5 | sed 's/^/      /'; } || true
  fi
fi
echo

# ── Step 7: Client health ─────────────────────────────────────────────────────
# Step 6 only proves the server; `make health` also probes each client's own
# registration. A client failure does not fail setup — the server is ready and
# health prints the exact `make use-http-*` fix.

HEALTH_OK=1
if [[ "$VERIFY_OK" == 1 ]]; then
  echo "步驟 7：檢查各 client 連線（make health）…"
  make -C "$PROJECT_DIR" --no-print-directory health || HEALTH_OK=0
  echo
fi

# ── Done ──────────────────────────────────────────────────────────────────────

if [[ "$VERIFY_OK" == 1 ]]; then
  echo "=== 設定完成 ==="
  echo
  if [[ "$HEALTH_OK" != 1 ]]; then
    echo "⚠️  部分 client 未通過健康檢查：依上方提示執行對應的 'make use-http-*'，再執行 'make health'"
    echo
  fi
  echo "下一步："
  ANY_CLIENT=0
  for _client in "${MCP_CLIENTS[@]}"; do
    command -v "$_client" &>/dev/null && ANY_CLIENT=1
  done
  if [[ "$ANY_CLIENT" == 1 ]]; then
    echo "  1. 完全結束已安裝的 Claude Code / Codex / Grok / AGY / Copilot，再重新開啟（才會載入新設定與 token）"
    echo "  2. 在任一 client 中問「幫我查看我的 Telegram 帳號資訊」測試"
    echo "  3. 之後若無法連線：執行 'make health' 檢查；server 異常時執行 'make restart'"
  else
    echo "  目前未偵測到 Claude Code、Codex、Grok、AGY 或 Copilot CLI；server 已就緒，但尚無 client 註冊。"
    echo "  安裝 client 後執行 'make use-http-<client>'（${MCP_CLIENTS[*]}），或 'make use-http' 一次設定全部。"
  fi
else
  echo "=== 設定尚未完成 ==="
  echo
  echo "server 無法正常提供服務，請依照上方診斷處理後重新執行本 script。"
  echo "重跑本 script 是安全的：已存在的憑證會被沿用，不會重複詢問。"
  exit 1
fi
