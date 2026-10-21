# z620-a4000-srv — operator interface.
# Mirrors the dgx-spark-srv Makefile where it makes sense.

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
ALL_PROFILES := vllm,kev

.PHONY: help init up down llm llm-stop restart apply logs ps health \
        build-kev download-models pull-stack \
        install-system prune prune-status backup usage-up usage-down usage-status

help:  ## Show this help.
	@awk 'BEGIN{FS=":.*##"; printf "Targets:\n"} /^[a-zA-Z_-]+:.*##/ {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

init:  ## Create docker network + storage roots. Run once.
	@docker network inspect apex >/dev/null 2>&1 || docker network create apex
	@mkdir -p $${ACTIVE_ROOT:-/data/active}/models/local
	@mkdir -p $${ARCHIVE_ROOT:-/archive}/models/{hf-cache,local}
	@mkdir -p $${ARCHIVE_ROOT:-/archive}/backups
	@echo "init: network 'apex' ready; storage roots created."

up:  ## Bring up TEI + Caddy + specified LLM; stops the other LLM if up. Usage: make up llm=<vllm|kev>
	@test -n "$(llm)" || { echo "usage: make up llm=<vllm|kev>"; exit 1; }
	@case "$(llm)" in vllm|kev) ;; *) echo "ERROR: llm must be 'vllm' or 'kev'"; exit 1 ;; esac
	@other=$$([ "$(llm)" = vllm ] && echo kev || echo vllm); \
	 if docker ps --format '{{.Names}}' | grep -q "^$$other$$"; then \
	   echo "Stopping $$other to free the GPU..."; \
	   docker stop $$other && docker rm $$other; \
	 fi
	COMPOSE_PROFILES=$(llm) $(COMPOSE) up -d
	@echo "Waiting for $(llm) healthy (up to 10 min for first cold load)..."
	@for i in $$(seq 1 120); do \
	  state=$$(docker inspect -f '{{.State.Health.Status}}' $(llm) 2>/dev/null || echo missing); \
	  [ "$$state" = "healthy" ] && { echo "$(llm) healthy."; break; }; \
	  sleep 5; \
	done

down:  ## Stop everything (containers + network state).
	COMPOSE_PROFILES=$(ALL_PROFILES) $(COMPOSE) down

llm:  ## Show which LLM container is up.
	@for s in vllm kev; do \
	  state=$$(docker inspect -f '{{.State.Status}}' $$s 2>/dev/null || echo "not created"); \
	  echo "$$s: $$state"; \
	done

llm-stop:  ## Stop both LLM services (keeps TEI + Caddy up).
	-@docker stop vllm kev 2>/dev/null; true
	-@docker rm   vllm kev 2>/dev/null; true

build-kev:  ## One-shot build of the kev-serve:local image on this box.
	cd kev && ./build-kev-image.sh

restart:  ## Restart a running service: `make restart svc=<vllm|kev|tei|tei-reranker|caddy>`
	@test -n "$(svc)" || { echo "usage: make restart svc=<vllm|kev|tei|tei-reranker|caddy>"; exit 1; }
	docker restart $(svc)

apply:  ## Recreate a service to pick up .env/compose/Caddyfile changes: `make apply svc=<...>`
	@test -n "$(svc)" || { echo "usage: make apply svc=<vllm|kev|tei|tei-reranker|caddy>"; exit 1; }
	@case "$(svc)" in \
	  vllm|kev) COMPOSE_PROFILES=$(svc) $(COMPOSE) up -d --force-recreate $(svc) ;; \
	  *)        COMPOSE_PROFILES=$(ALL_PROFILES) $(COMPOSE) up -d --force-recreate $(svc) ;; \
	esac

logs:  ## Tail logs. `make logs svc=<svc>` or omit svc for everything that's up.
	COMPOSE_PROFILES=$(ALL_PROFILES) $(COMPOSE) logs -f --tail=200 $(svc)

ps:  ## List stack containers (including stopped ones in both profiles).
	COMPOSE_PROFILES=$(ALL_PROFILES) $(COMPOSE) ps

health:  ## Run health.sh (PASS/WARN/FAIL probes; non-zero on FAIL).
	@./health.sh

download-models:  ## Pre-download VLLM_MODEL + TEI_MODEL via hf CLI.
	@./download-models.sh

pull-stack:  ## Skopeo-based image pull (proxy fallback).
	@./skopeo-pull-stack.sh

install-system:  ## Install docker log rotation + journald cap.
	@sudo ./install-system.sh

# Never removes tagged images: with vllm/kev time-sharing, the idle LLM's
# image has no running container, and `image prune -a` would delete it
# (kev-serve:local is a 15-30 min rebuild). Remove a specific image with
# `docker rmi <repo:tag>` instead.
prune:  ## Reclaim stopped containers, dangling images, build cache >14d. Keeps all tagged images.
	docker container prune -f
	docker image prune -f
	docker builder prune -f --filter until=336h

prune-status:  ## Show reclaimable docker space (read-only).
	docker system df
	@echo "---"
	@docker images --format '{{.Size}}\t{{.Repository}}:{{.Tag}}' | sort -h | tail -20

backup:  ## Run backup.sh (config + models manifest + restic if configured).
	@./backup.sh

# ── Claude Code usage observability (standalone stack in claude-usage/) ────
# Independent compose project; Caddy proxies /grafana/ to its host port 3000.
# Full interface: `make -C claude-usage help`.
usage-up:  ## Start the claude-usage stack (collector + Prometheus + Grafana).
	@$(MAKE) -C claude-usage init up

usage-down:  ## Stop the claude-usage stack.
	@$(MAKE) -C claude-usage down

usage-status:  ## Health of the claude-usage stack.
	@$(MAKE) -C claude-usage status
