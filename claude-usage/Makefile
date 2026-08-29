# claude-usage — operator interface.
#   make init        create data dirs (no sudo)
#   make up / down   start / stop the stack
#   make status      is everything up and receiving?
#   make grant host=alice@ws-01 models=opus hours=4    (also: revoke, grants)
SHELL := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := help

ifneq (,$(wildcard .env))
include .env
export
endif
export PUID ?= $(shell id -u)
export PGID ?= $(shell id -g)
DATA_ROOT ?= ./data
COMPOSE := docker compose

.PHONY: help init up down restart logs ps status grant revoke grants

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init:  ## Create data dirs (owned by you; containers run as your uid). Run once.
	@test -f .env || { cp .env.example .env; echo "created .env from .env.example — edit GRAFANA_PASSWORD"; }
	@mkdir -p $(DATA_ROOT)/prometheus $(DATA_ROOT)/grafana
	@echo "init: data dirs under $(DATA_ROOT) ready (uid $(PUID))"

up:  ## Start collector + Prometheus + Grafana.
	@$(COMPOSE) up -d
	@echo "Grafana: http://$$(hostname -I 2>/dev/null | awk '{print $$1}'):$${GRAFANA_PORT:-3000}/  (dashboard: /d/apex-claude-code-usage)"
	@echo "Clients point at: http://<this-host>:$${OTLP_GRPC_PORT:-4317}  → clients/claude-code/install-managed-settings.sh"

down:  ## Stop the stack (data kept).
	$(COMPOSE) down

restart:  ## Restart one service: make restart svc=prometheus
	@test -n "$(svc)" || { echo "usage: make restart svc=<otel-collector|prometheus|grafana>"; exit 1; }
	$(COMPOSE) up -d --force-recreate $(svc)

logs:  ## Tail logs: make logs svc=otel-collector (omit svc for all)
	$(COMPOSE) logs -f --tail=200 $(svc)

ps:  ## List containers.
	$(COMPOSE) ps

status:  ## Health: containers, collector endpoint, Prometheus target, series seen.
	@$(COMPOSE) ps --format 'table {{.Name}}\t{{.Status}}'
	@echo "--- collector /metrics (internal :8889)"
	@docker exec claude-usage-prometheus wget -qO- http://otel-collector:8889/metrics 2>/dev/null | grep -c '^claude_code_' | sed 's/^/  claude_code_* series: /' || echo "  collector not reachable"
	@echo "--- prometheus target"
	@docker exec claude-usage-prometheus wget -qO- 'http://localhost:9090/api/v1/targets' 2>/dev/null | grep -o '"scrapePool":"claude-code"[^}]*' | grep -o '"health":"[a-z]*"' | sed 's/"health":/  claude-code: /' || echo "  prometheus not reachable"
	@echo "--- users seen (last 24h)"
	@docker exec claude-usage-prometheus wget -qO- 'http://localhost:9090/api/v1/query?query=count%20by%20(user_email)%20(last_over_time(claude_code_session_count%5B24h%5D))' 2>/dev/null | grep -o '"user_email":"[^"]*"' | sed 's/"user_email":/  /' || true

# ── model grants on developer machines (Linux/WSL over ssh, or host=local) ──
grant:  ## make grant host=alice@ws-01 models=opus[,fable] hours=4
	@test -n "$(host)" -a -n "$(models)" || { echo "usage: make grant host=<user@host|local> models=opus[,fable] [hours=4]"; exit 1; }
	./clients/claude-code/grant-model.sh $(host) grant $(models) $(or $(hours),4)

revoke:  ## make revoke host=alice@ws-01 models=opus   (or models=--all)
	@test -n "$(host)" -a -n "$(models)" || { echo "usage: make revoke host=<user@host|local> models=<opus|--all>"; exit 1; }
	./clients/claude-code/grant-model.sh $(host) revoke $(models)

grants:  ## make grants host=alice@ws-01   — list active grants there
	@test -n "$(host)" || { echo "usage: make grants host=<user@host|local>"; exit 1; }
	./clients/claude-code/grant-model.sh $(host) list
