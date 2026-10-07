# Makefile - local development and MCP client convenience commands.

.DEFAULT_GOAL := list

PROJECT_ROOT := $(CURDIR)
START_SCRIPT := $(PROJECT_ROOT)/scripts/start.sh
HEADERS_HELPER := $(PROJECT_ROOT)/scripts/mcp-auth-headers.sh
CLIENT_SCRIPT := $(PROJECT_ROOT)/scripts/mcp-client.sh
HEALTH_SCRIPT := $(PROJECT_ROOT)/scripts/health-check.sh
SETUP_SCRIPT := $(PROJECT_ROOT)/scripts/setup.sh
ENV_FILE := $(PROJECT_ROOT)/.env

# Same precedence as scripts/mcp-endpoint.sh: a command-line or environment
# override wins (`?=`), then .env — the file the server itself reads via
# load_dotenv — and only then the built-in default.
env_get = $(shell [ -f "$(ENV_FILE)" ] && sed -n 's/^[[:space:]]*$(1)[[:space:]]*=[[:space:]]*\([^[:space:]\#]*\).*/\1/p' "$(ENV_FILE)" | tail -1 | tr -d "\"'")

MCP_NAME ?= telegram-mcp
LAUNCHD_LABEL ?= com.telegram-mcp.server
RESTART_TIMEOUT ?= 30
MCP_HOST ?= $(or $(call env_get,MCP_HOST),127.0.0.1)
MCP_PORT ?= $(or $(call env_get,MCP_PORT),8765)
HTTP_URL ?= http://$(MCP_HOST):$(MCP_PORT)/mcp
SSE_URL ?= http://$(MCP_HOST):$(MCP_PORT)/sse
CLAUDE ?= claude
CODEX ?= codex
GROK ?= grok
AGY ?= agy
COPILOT ?= copilot
CODEX_BEARER_ENV ?= TELEGRAM_MCP_TOKEN
GROK_BEARER_ENV ?= TELEGRAM_MCP_TOKEN
AGY_BEARER_ENV ?= TELEGRAM_MCP_TOKEN
COPILOT_BEARER_ENV ?= TELEGRAM_MCP_TOKEN
UV ?= uv

# Every value scripts/mcp-client.sh reads, so each client target is one line.
CLIENT = @MCP_NAME="$(MCP_NAME)" HTTP_URL="$(HTTP_URL)" SSE_URL="$(SSE_URL)" \
	HEADERS_HELPER="$(HEADERS_HELPER)" PROJECT_ROOT="$(PROJECT_ROOT)" START_SCRIPT="$(START_SCRIPT)" \
	CLAUDE="$(CLAUDE)" CODEX="$(CODEX)" GROK="$(GROK)" AGY="$(AGY)" COPILOT="$(COPILOT)" \
	CODEX_BEARER_ENV="$(CODEX_BEARER_ENV)" GROK_BEARER_ENV="$(GROK_BEARER_ENV)" \
	AGY_BEARER_ENV="$(AGY_BEARER_ENV)" COPILOT_BEARER_ENV="$(COPILOT_BEARER_ENV)" \
	bash "$(CLIENT_SCRIPT)"

.PHONY: list help setup restart start start-http start-sse start-stdio health config-check config-check-claude config-check-codex config-check-grok config-check-agy config-check-copilot use-http use-http-claude use-http-codex use-http-grok use-http-agy use-http-copilot use-sse use-sse-claude use-stdio use-stdio-claude use-stdio-codex use-stdio-grok use-stdio-agy use-stdio-copilot sync-upstream-readme

list:
	@echo "Available commands:"
	@echo ""
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-24s\033[0m %s\n", "make " $$1, $$2}'
	@echo ""

help: list ## Same as list; show available commands

setup: ## One-shot install: credentials, Keychain, launchd HTTP server, MCP clients
	bash "$(SETUP_SCRIPT)"

start: start-http ## Run HTTP mode in foreground

start-http: ## Run Streamable HTTP mode in foreground on /mcp (MCP_HOST/MCP_PORT or .env)
	MCP_HOST=$(MCP_HOST) "$(START_SCRIPT)" --transport http --port $(MCP_PORT)

start-sse: ## Run legacy SSE mode in foreground on /sse (MCP_HOST/MCP_PORT or .env)
	MCP_HOST=$(MCP_HOST) "$(START_SCRIPT)" --transport sse --port $(MCP_PORT)

start-stdio: ## Run stdio mode in foreground
	"$(START_SCRIPT)" --transport stdio

restart: ## Restart the launchd service, wait for MCP_PORT, then run health
	@set -e; \
	echo "Restarting $(LAUNCHD_LABEL) ..."; \
	launchctl kickstart -k "gui/$$(id -u)/$(LAUNCHD_LABEL)" || { echo "Service not found/running — install it first: bash scripts/install-launchd.sh"; exit 1; }; \
	echo "Waiting for $(MCP_HOST):$(MCP_PORT) (up to $(RESTART_TIMEOUT)s) ..."; \
	i=0; until nc -z $(MCP_HOST) $(MCP_PORT); do \
		i=$$((i+1)); \
		[ $$i -ge $(RESTART_TIMEOUT) ] && { echo "Timed out waiting for $(MCP_HOST):$(MCP_PORT)"; exit 1; }; \
		[ $$((i % 5)) -eq 0 ] && echo "  ... still waiting ($${i}s/$(RESTART_TIMEOUT)s), server may still be starting"; \
		sleep 1; \
	done
	@$(MAKE) --no-print-directory health

health: ## Check telegram-mcp health across launchd, HTTP server, and Claude/Codex/Grok/AGY/Copilot registration
	@MCP_HOST=$(MCP_HOST) MCP_PORT=$(MCP_PORT) MCP_NAME=$(MCP_NAME) CLAUDE=$(CLAUDE) CODEX=$(CODEX) GROK=$(GROK) AGY=$(AGY) COPILOT=$(COPILOT) "$(HEALTH_SCRIPT)"

config-check: ## Show current Claude, Codex, Grok, AGY, and Copilot MCP config for telegram (in parallel)
	$(CLIENT) config-check all

config-check-claude: ## Show current Claude user-scope MCP config
	$(CLIENT) config-check claude

config-check-codex: ## Show current Codex MCP config
	$(CLIENT) config-check codex

config-check-grok: ## Show current Grok MCP config
	$(CLIENT) config-check grok

config-check-agy: ## Show current AGY MCP config
	$(CLIENT) config-check agy

config-check-copilot: ## Show current GitHub Copilot CLI MCP config
	$(CLIENT) config-check copilot

use-http: ## Switch Claude, Codex, Grok, AGY, and Copilot MCP config to Streamable HTTP (in parallel)
	$(CLIENT) register all http
	@echo "Finished configuring installed MCP clients for Streamable HTTP. Missing CLIs were skipped."

use-http-claude: ## Switch Claude MCP config to authenticated Streamable HTTP
	$(CLIENT) register claude http

use-http-codex: ## Switch Codex MCP config to authenticated Streamable HTTP
	$(CLIENT) register codex http

use-http-grok: ## Switch Grok MCP config to authenticated Streamable HTTP
	$(CLIENT) register grok http

use-http-agy: ## Switch AGY MCP config to authenticated Streamable HTTP
	$(CLIENT) register agy http

use-http-copilot: ## Switch GitHub Copilot CLI MCP config to authenticated Streamable HTTP
	$(CLIENT) register copilot http

use-sse: use-sse-claude ## Switch Claude MCP config to legacy SSE (Codex/Grok/AGY/Copilot keep their current transport)
	@echo "Codex, Grok, AGY, and Copilot were left unchanged; this target only switches Claude to legacy SSE."

use-sse-claude: ## Switch Claude MCP config to authenticated legacy SSE
	$(CLIENT) register claude sse

use-stdio: ## Switch Claude, Codex, Grok, AGY, and Copilot MCP config to stdio (in parallel)
	$(CLIENT) register all stdio
	@echo "Finished configuring installed MCP clients for stdio. Missing CLIs were skipped."

use-stdio-claude: ## Switch Claude MCP config back to stdio
	$(CLIENT) register claude stdio

use-stdio-codex: ## Switch Codex MCP config back to stdio
	$(CLIENT) register codex stdio

use-stdio-grok: ## Switch Grok MCP config back to stdio
	$(CLIENT) register grok stdio

use-stdio-agy: ## Switch AGY MCP config back to stdio
	$(CLIENT) register agy stdio

use-stdio-copilot: ## Switch GitHub Copilot CLI MCP config back to stdio
	$(CLIENT) register copilot stdio

sync-upstream-readme: ## Refresh README.upstream.md from upstream/main (never edit it by hand)
	@git remote get-url upstream >/dev/null 2>&1 || { echo "No 'upstream' remote. Add it: git remote add upstream https://github.com/chigwell/telegram-mcp.git"; exit 1; }
	@echo "Fetching upstream..."
	@git fetch upstream
	@git show upstream/main:README.md > README.upstream.md
	@echo "README.upstream.md updated from upstream/main"
