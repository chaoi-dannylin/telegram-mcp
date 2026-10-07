# 🛰️ Telegram MCP Server — 強化版 Fork Project

> Fork of [chigwell/telegram-mcp](https://github.com/chigwell/telegram-mcp)。
> 在原本的 Telegram MCP 伺服器之上，新增**一鍵安裝與常駐 HTTP 服務**、
> **Keychain 優先的 Session 儲存**、**危險工具預設停用的存取控制**、
> **顯示時區預設 UTC+8**，以及一份完整的**繁體中文安裝指南**。
>
> 📖 原作者的完整工具清單與 API 參數說明請見 **[README.upstream.md](README.upstream.md)**。

---

## ⚡ 快速開始

> 📖 **初次設定？請直接照 [SETUP.md](SETUP.md) 逐步操作**，涵蓋 uv 安裝、Telegram API 憑證申請、產生 Session String、環境設定到掛載 Claude 的完整流程。

回訪速查：在專案目錄執行 `make setup` 一鍵安裝並登記到 Claude user scope（所有專案共用）。首次安裝會建立 `~/Downloads/telegram_mcp_files` 作為專用檔案交換目錄。

```bash
make setup
```

（等同 `bash scripts/setup.sh`。）

服務管理、HTTP／stdio／SSE 切換、多帳號等指令見 **[SETUP.md § Makefile 指令](SETUP.md)**，或執行 `make list`。

---

## 🔄 Version migration：allowed roots

若是從舊版升級，請在終端機依序執行以下指令：

```bash
cd <project_root>
mkdir -p "$HOME/Downloads/telegram_mcp_files"

# 若舊版目錄存在且新目錄尚未建立，搬移既有下載檔案
if [[ -d "$HOME/Telegram-MCP-Files" && ! -e "$HOME/Downloads/telegram_mcp_files" ]]; then
  mv "$HOME/Telegram-MCP-Files" "$HOME/Downloads/telegram_mcp_files"
fi
```

接著編輯 `<project_root>/.env`：

```dotenv
TELEGRAM_MCP_ALLOWED_ROOTS="~/Downloads/telegram_mcp_files,<project_root>/docs/chat"
```

請把兩個 `<project_root>` 都替換成實際專案絕對路徑。若舊設定使用冒號分隔，必須改成逗號分隔；不要把 `<project_root>` 原樣保留在 `.env`。

重新安裝並重啟 launchd：

```bash
bash scripts/install-launchd.sh
make restart
```

`make restart` 會重啟 launchd 服務、等待 `.env` 的 `MCP_PORT`（未設定時為 8765）就緒，再跑 `make health`。

完成後，`download_media` 未指定路徑時會使用 `~/Downloads/telegram_mcp_files/downloads/`；`telegram-summary` 的附件則保存於 `<project_root>/docs/chat/<對話名稱>/media/`。

---

## ✨ 這個 Fork 多了什麼

相對於上游，本 fork 額外提供：

### 🚀 一鍵安裝與常駐 HTTP 服務

- `make setup`（= `bash scripts/setup.sh`）：一次安裝、將 bearer token 存入 Keychain、建立專用 allowed root `~/Downloads/telegram_mcp_files`，偵測內嵌 telegram-mcp 專案或 `TELEGRAM_MCP_SUMMARY_PROJECT` 後只額外授權其 `docs/chat/`，並把 Claude Code、Codex、Grok、AGY 與 Copilot 設為連向同一個本機 HTTP server。
- `scripts/install-launchd.sh`：安裝 launchd 服務並開機自啟，讓 HTTP server 常駐。
- launchd 用的 stateless streamable HTTP 傳輸無法向 client 發出 Roots 請求，因此檔案工具只能使用啟動時明確授權的 server roots；沒有 roots 時，`download_media`、`send_file` 等工具會安全停用。`TELEGRAM_MCP_ALLOWED_ROOTS="~/Downloads/telegram_mcp_files,<project_root>/docs/chat"` 可放在 `.env`，請將 `<project_root>` 替換成該電腦的實際絕對路徑；它會與 installer／CLI roots 合併。`TELEGRAM_ALLOW_SERVER_ROOTS_FALLBACK=1` 本身不會建立 root。`telegram-summary` 解析圖片時優先使用不落地的 `open_photo`，需要保存附件時使用授權的專案 `docs/chat/`。詳見 [SETUP.md 的 allowed roots 說明](SETUP.md#檔案交換目錄allowed-roots)。

### 🔐 Keychain 優先的 Session 儲存

- Session String 優先存入系統 Keychain，`.env` 作為 fallback，降低純文字外洩風險。

### 🛡️ 危險工具預設停用的存取控制

- 危險工具（發送、刪除、封鎖等）**預設停用**；用 `TELEGRAM_ENABLE_TOOLS`、`TELEGRAM_EXTRA_UNBLOCKED_TOOLS`、`TELEGRAM_EXTRA_BLOCKED_TOOLS` 精確控制暴露的工具面。
- 細節與衝突規則見 [SETUP.md § 工具存取控制](SETUP.md)。

### 🕒 顯示時區預設 UTC+8

- 時間欄位預設以 UTC+8 呈現，可用 `TELEGRAM_DISPLAY_UTC_OFFSET` 調整。

### 🛠️ 開發者便利工具

- 繁體中文安裝指南 **[SETUP.md](SETUP.md)**。
- Makefile 便利指令：`make start-http`、`make use-http`、`make use-sse`、`make use-stdio`、`make config-check`、`make health`… 執行 `make list` 查看全部。
- SSE bearer 驗證輔助腳本 `scripts/mcp-auth-headers.sh`。
- HTTP 位址集中於 `.env` 的 `MCP_HOST` / `MCP_PORT`：Makefile 與各腳本都經由 `scripts/mcp-endpoint.sh` 解析（環境變數 → `.env` → 預設 `127.0.0.1:8765`），沒設定就用預設值。

---

## 📂 文件導覽

| 檔案                                     | 內容                                                       |
| ---------------------------------------- | ---------------------------------------------------------- |
| [SETUP.md](SETUP.md)                     | 完整安裝、Session 取得、常駐服務、工具存取控制設定（繁中） |
| [README.upstream.md](README.upstream.md) | 上游原始 README：完整工具清單與 API 參數                   |

---

## 🔄 與上游同步

- 例行更新上游 README 參照：`make sync-upstream-readme`（絕不手動編輯 `README.upstream.md`）。
- 完整合併上游修正／新工具：見 `/sync-upstream` 指令（[.claude/commands/sync-upstream.md](.claude/commands/sync-upstream.md)）。
- 裝好 `post-merge` hook（`uv run pre-commit install --hook-type post-merge`）後，每次 `git merge`／`git pull` 都會自動跑上面那個 `make sync-upstream-readme`（有設定 `upstream` remote 才會動作），只會更新檔案不會自動 commit。

---

## 🙏 致謝

本專案 fork 自 [chigwell/telegram-mcp](https://github.com/chigwell/telegram-mcp)。
核心 Telegram MCP 工具由原作者（[@chigwell](https://github.com/chigwell)、[@l1v0n1](https://github.com/l1v0n1)）開發；本 fork 著重於部署體驗、Session 維運與工具存取控制。

## 📄 授權

Apache 2.0（與上游一致），見 [LICENSE](LICENSE)。
