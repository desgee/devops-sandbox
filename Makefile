# devops-sandbox Makefile
# All targets documented. Run `make help` to see available commands.

SHELL := /bin/bash
.PHONY: help up down create destroy logs health simulate clean status inspect build-app test test-lifecycle monitoring-up monitoring-down monitoring-status

# ── Config ────────────────────────────────────────────────────────────────────
ROOT_DIR := $(shell pwd)
PLATFORM := $(ROOT_DIR)/platform
ENV_FILE  := $(ROOT_DIR)/.env

# Ensure .env exists
$(ENV_FILE):
	@cp .env.example .env
	@echo "⚠️  Created .env from .env.example — edit it before proceeding"

# ── Help ──────────────────────────────────────────────────────────────────────
help:
	@echo ""
	@echo "╔════════════════════════════════════════════════════════╗"
	@echo "║          devops-sandbox — Make Targets                 ║"
	@echo "╠════════════════════════════════════════════════════════╣"
	@echo "║  make up                    Start Nginx, daemon & API  ║"
	@echo "║  make down                  Stop everything            ║"
	@echo "║  make create                Create a new environment   ║"
	@echo "║  make destroy ENV=<id>      Destroy specific env       ║"
	@echo "║  make logs ENV=<id>         Tail env app logs          ║"
	@echo "║  make health                Show all env health        ║"
	@echo "║  make simulate ENV=<id> MODE=<mode>  Run outage sim    ║"
	@echo "║  make status                List all active envs       ║"
	@echo "║  make inspect ENV=<id>      Inspect single environment ║"
	@echo "║  make build-app             Build demo app image       ║"
	@echo "║  make test                  Run API integration tests  ║"
	@echo "║  make test-lifecycle        Run lifecycle test         ║"
	@echo "║  make monitoring-up         Start Netdata dashboard    ║"
	@echo "║  make monitoring-down       Stop Netdata               ║"
	@echo "║  make monitoring-status     Check Netdata status       ║"
	@echo "║  make clean                 Wipe all state & logs      ║"
	@echo "╚════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "  Outage modes: crash | pause | network | recover | stress"
	@echo ""

# ── Startup ───────────────────────────────────────────────────────────────────
up: $(ENV_FILE)
	@echo "🚀 Starting devops-sandbox platform..."
	@mkdir -p logs envs nginx/conf.d
	@touch nginx/conf.d/.gitkeep
	@docker compose up -d --build
	@echo ""
	@echo "✅ Platform running:"
	@echo "   Nginx:  http://localhost:$$(grep NGINX_PORT .env | cut -d= -f2 || echo 8080)"
	@echo "   API:    http://localhost:$$(grep API_PORT .env | cut -d= -f2 || echo 7000)"
	@echo ""
	@echo "   Quick test: curl http://localhost:7000/envs"

# ── Shutdown ──────────────────────────────────────────────────────────────────
down:
	@echo "⏹️  Stopping platform and destroying all environments..."
	@for f in envs/*.json; do \
		[ -f "$$f" ] || continue; \
		ENV_ID=$$(basename $$f .json); \
		echo "   Destroying $$ENV_ID..."; \
		bash $(PLATFORM)/destroy_env.sh "$$ENV_ID" 2>/dev/null || true; \
	done
	@docker compose down --remove-orphans
	@echo "✅ Platform stopped."

# ── Create Environment ────────────────────────────────────────────────────────
create:
	@read -p "Environment name: " name; \
	read -p "TTL in seconds [1800]: " ttl; \
	ttl=$${ttl:-1800}; \
	bash $(PLATFORM)/create_env.sh "$$name" "$$ttl"

# ── Destroy Environment ───────────────────────────────────────────────────────
destroy:
ifndef ENV
	$(error ❌ ENV is required. Usage: make destroy ENV=env-abc123)
endif
	@bash $(PLATFORM)/destroy_env.sh $(ENV)

# ── Tail Logs ─────────────────────────────────────────────────────────────────
logs:
ifndef ENV
	$(error ❌ ENV is required. Usage: make logs ENV=env-abc123)
endif
	@LOG_FILE=logs/$(ENV)/app.log; \
	ARCHIVE=logs/archived/$(ENV)/app.log; \
	if [ -f "$$LOG_FILE" ]; then \
		echo "📋 Tailing $$LOG_FILE"; \
		tail -f "$$LOG_FILE"; \
	elif [ -f "$$ARCHIVE" ]; then \
		echo "📋 (archived) $$ARCHIVE"; \
		tail -n 100 "$$ARCHIVE"; \
	else \
		echo "❌ No logs found for $(ENV)"; \
	fi

# ── Health Dashboard ──────────────────────────────────────────────────────────
health:
	@echo ""
	@echo "╔══════════════════════════════════════════════════════════╗"
	@echo "║               Environment Health Status                  ║"
	@echo "╠══════════════════════════════════════════════════════════╣"
	@count=0; \
	for f in envs/*.json; do \
		[ -f "$$f" ] || continue; \
		count=$$((count+1)); \
		ENV_ID=$$(basename $$f .json); \
		NAME=$$(python3 -c "import json; print(json.load(open('$$f')).get('name','?'))"); \
		STATUS=$$(python3 -c "import json; print(json.load(open('$$f')).get('status','?'))"); \
		CREATED_EPOCH=$$(python3 -c "import json; print(json.load(open('$$f')).get('created_at_epoch',0))"); \
		TTL=$$(python3 -c "import json; print(json.load(open('$$f')).get('ttl',1800))"); \
		EXPIRES=$$((CREATED_EPOCH + TTL)); \
		REMAINING=$$((EXPIRES - $$(date +%s))); \
		PORT=$$(python3 -c "import json; print(json.load(open('$$f')).get('port','?'))"); \
		LAST_HEALTH=$$(tail -n1 "logs/$$ENV_ID/health.log" 2>/dev/null | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('status','?') + ' ' + str(d.get('latency_ms','?')) + 'ms')" 2>/dev/null || echo "no data"); \
		echo "║  $$ENV_ID"; \
		echo "║    name=$$NAME  status=$$STATUS  port=$$PORT"; \
		echo "║    ttl_remaining=$${REMAINING}s  last_check=$$LAST_HEALTH"; \
		echo "║"; \
	done; \
	if [ $$count -eq 0 ]; then echo "║  (no active environments)"; echo "║"; fi; \
	echo "╚══════════════════════════════════════════════════════════╝"

# ── Status (API) ──────────────────────────────────────────────────────────────
status:
	@curl -s http://localhost:7000/envs | python3 -m json.tool 2>/dev/null || \
		echo "❌ API not reachable — is the platform running? (make up)"

# ── Outage Simulation ─────────────────────────────────────────────────────────
simulate:
ifndef ENV
	$(error ❌ ENV is required. Usage: make simulate ENV=env-abc123 MODE=crash)
endif
ifndef MODE
	$(error ❌ MODE is required. Usage: make simulate ENV=env-abc123 MODE=crash)
endif
	@bash $(PLATFORM)/simulate_outage.sh --env $(ENV) --mode $(MODE)

# ── Build demo app ────────────────────────────────────────────────────────────
build-app:
	@bash scripts/build_demo_app.sh

# ── Inspect single env ────────────────────────────────────────────────────────
inspect:
ifndef ENV
	@bash scripts/inspect.sh
else
	@bash scripts/inspect.sh $(ENV)
endif

# ── Tests ─────────────────────────────────────────────────────────────────────
test:
	@bash tests/test_api.sh

test-lifecycle: build-app
	@bash tests/test_lifecycle.sh

# ── Optional monitoring stack ─────────────────────────────────────────────────
monitoring-up:
	@echo "📊 Starting Netdata monitoring..."
	@docker compose -f docker-compose.yml -f docker-compose.monitoring.yml up -d netdata
	@echo ""
	@echo "✅ Netdata dashboard: http://localhost:$$(grep NETDATA_PORT .env 2>/dev/null | cut -d= -f2 || echo 19999)"
	@echo "   Auto-discovering all sandbox containers — no setup needed."

monitoring-down:
	@docker compose -f docker-compose.yml -f docker-compose.monitoring.yml stop netdata
	@docker compose -f docker-compose.yml -f docker-compose.monitoring.yml rm -f netdata

monitoring-status:
	@echo "Netdata container:"
	@docker inspect sandbox-netdata --format \
		"  status={{.State.Status}}  started={{.State.StartedAt}}" 2>/dev/null \
		|| echo "  (not running — try: make monitoring-up)"
	@echo ""
	@echo "Dashboard: http://localhost:$$(grep NETDATA_PORT .env 2>/dev/null | cut -d= -f2 || echo 19999)"

# ── Cleanup ───────────────────────────────────────────────────────────────────
clean:
	@echo "🧹 Wiping all state, logs, and archives..."
	@for f in envs/*.json; do \
		[ -f "$$f" ] || continue; \
		ENV_ID=$$(basename $$f .json); \
		bash $(PLATFORM)/destroy_env.sh "$$ENV_ID" 2>/dev/null || true; \
	done
	@rm -rf logs/archived/* logs/*.log
	@find logs/ -name "*.log" -delete 2>/dev/null || true
	@find logs/ -name "*.pid" -delete 2>/dev/null || true
	@rm -f nginx/conf.d/*.conf
	@echo "✅ Clean complete."
