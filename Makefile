# z620-a4000-srv — operator interface.
# Mirrors the dgx-spark-srv Makefile so muscle memory carries over.

SHELL := /bin/bash
.ONESHELL:
.DEFAULT_GOAL := help

# `make foo` reads .env into the environment for compose + scripts that need it.
ifneq (,$(wildcard .env))
include .env
export
endif

COMPOSE_FILES := -f compose.inference.yml -f compose.gateway.yml
COMPOSE := docker compose $(COMPOSE_FILES)

.PHONY: help init up down restart apply logs ps health \
        vllm-start vllm-stop rebalance \
        download-models pull-stack \
        install-system prune prune-status backup

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init:  ## Create docker network + storage roots. Run once.
	@docker network inspect apex >/dev/null 2>&1 || docker network create apex
	@mkdir -p $${ACTIVE_ROOT:-/data/active}/models/local
	@mkdir -p $${ARCHIVE_ROOT:-/archive}/models/{hf-cache,local,ollama}
	@mkdir -p $${ARCHIVE_ROOT:-/archive}/backups
	@echo "init: network 'apex' ready; storage roots created."

up:  ## Bring up the stack (vLLM first, then Ollama + TEI + gateway).
	$(COMPOSE) up -d vllm
	@echo "Waiting for vLLM /health (up to 5 min for first cold load)..."
	@for i in $$(seq 1 60); do \
	  docker exec vllm python3 -c 'import urllib.request,sys;sys.exit(0 if urllib.request.urlopen("http://localhost:8000/health",timeout=2).status==200 else 1)' 2>/dev/null && break; \
	  sleep 5; \
	done
	$(COMPOSE) up -d

down:  ## Stop everything (containers + network state).
	$(COMPOSE) down

restart:  ## Restart one service (does NOT apply .env/compose changes): `make restart svc=vllm`
	@test -n "$(svc)" || { echo "usage: make restart svc=<vllm|ollama|tei|tei-reranker|caddy>"; exit 1; }
	$(COMPOSE) restart $(svc)

apply:  ## Recreate a service so .env/compose/Caddyfile changes take effect: `make apply svc=vllm`
	@test -n "$(svc)" || { echo "usage: make apply svc=<vllm|ollama|tei|tei-reranker|caddy>"; exit 1; }
	$(COMPOSE) up -d --force-recreate $(svc)

logs:  ## Tail logs. `make logs svc=vllm` or omit svc for all.
	$(COMPOSE) logs -f --tail=200 $(svc)

ps:  ## List stack containers.
	$(COMPOSE) ps

health:  ## Run health.sh (PASS/WARN/FAIL probes; non-zero on FAIL).
	@./health.sh

vllm-start:  ## Start vLLM only (reclaims VLLM_GPU_UTIL slice).
	$(COMPOSE) up -d vllm

vllm-stop:  ## Stop vLLM only (frees full 16 GB VRAM for Ollama).
	$(COMPOSE) stop vllm

rebalance:  ## Change vLLM/Ollama VRAM split: `make rebalance util=0.55`
	@test -n "$(util)" || { echo "usage: make rebalance util=<0.30..0.85>"; exit 1; }
	@grep -q '^VLLM_GPU_UTIL=' .env && sed -i "s|^VLLM_GPU_UTIL=.*|VLLM_GPU_UTIL=$(util)|" .env || echo "VLLM_GPU_UTIL=$(util)" >> .env
	$(COMPOSE) up -d --force-recreate vllm
	@echo "vLLM restarted with VLLM_GPU_UTIL=$(util)"

download-models:  ## Pre-download VLLM_MODEL + TEI_MODEL via hf CLI.
	@./download-models.sh

pull-stack:  ## Skopeo-based image pull (proxy fallback).
	@./skopeo-pull-stack.sh

install-system:  ## Install docker log rotation + journald cap.
	@sudo ./install-system.sh

prune:  ## Reclaim images >14d, stopped containers, build cache.
	docker image prune -a --filter "until=336h" -f
	docker container prune -f
	docker builder prune -f

prune-status:  ## Show reclaimable docker space (read-only).
	docker system df
	@echo "---"
	@docker images --format '{{.Size}}\t{{.Repository}}:{{.Tag}}' | sort -h | tail -20

backup:  ## Run backup.sh (config + models manifest + restic if configured).
	@./backup.sh
