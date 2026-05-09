#!/usr/bin/env bash
# tests/test_lifecycle.sh — End-to-end lifecycle test
# Tests: create → health check → outage simulation → recover → destroy
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM="$ROOT_DIR/platform"

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
info()  { printf '\033[0;34m%s\033[0m\n' "$*"; }

echo ""
echo "════════════════════════════════════════"
echo " devops-sandbox — Lifecycle Test"
echo "════════════════════════════════════════"
echo ""

# ── Create ───────────────────────────────────────────────────────────────────
info "Step 1: Create environment"
bash "$PLATFORM/create_env.sh" lifecycle-test 120
ENV_ID=$(ls "$ROOT_DIR/envs/" | grep '^env-' | sort -t- -k2 -n | tail -1 | sed 's/\.json//')
green "  Created: $ENV_ID"

# ── Verify state file ─────────────────────────────────────────────────────────
info "Step 2: Verify state file"
STATE="$ROOT_DIR/envs/$ENV_ID.json"
[[ -f "$STATE" ]] && green "  State file exists: $STATE" || { red "  FAIL: no state file"; exit 1; }
STATUS=$(python3 -c "import json; print(json.load(open('$STATE'))['status'])")
[[ "$STATUS" == "running" ]] && green "  Status: $STATUS" || { red "  FAIL: status=$STATUS"; exit 1; }

# ── Verify container ─────────────────────────────────────────────────────────
info "Step 3: Verify container"
docker inspect "sandbox-app-$ENV_ID" > /dev/null 2>&1 && green "  Container exists" || { red "  FAIL: container not found"; exit 1; }

# ── Verify Nginx config ───────────────────────────────────────────────────────
info "Step 4: Verify Nginx config"
[[ -f "$ROOT_DIR/nginx/conf.d/$ENV_ID.conf" ]] && green "  Nginx config exists" || { red "  FAIL: no nginx config"; exit 1; }

# ── App health ────────────────────────────────────────────────────────────────
info "Step 5: App /health check"
PORT=$(python3 -c "import json; print(json.load(open('$STATE'))['port'])")
sleep 2
HTTP=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health")
[[ "$HTTP" == "200" ]] && green "  HTTP $HTTP from localhost:$PORT/health" || { red "  FAIL: HTTP $HTTP"; exit 1; }

# ── Simulate crash ────────────────────────────────────────────────────────────
info "Step 6: Simulate crash"
bash "$PLATFORM/simulate_outage.sh" --env "$ENV_ID" --mode crash
sleep 1
CSTATUS=$(docker inspect --format='{{.State.Status}}' "sandbox-app-$ENV_ID" 2>/dev/null || echo "not_found")
[[ "$CSTATUS" != "running" ]] && green "  Container is $CSTATUS (expected)" || red "  WARN: container still running after crash"

# ── Recover ────────────────────────────────────────────────────────────────────
info "Step 7: Recover"
bash "$PLATFORM/simulate_outage.sh" --env "$ENV_ID" --mode recover
sleep 2
HTTP=$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/health")
[[ "$HTTP" == "200" ]] && green "  HTTP $HTTP — recovered" || { red "  FAIL: HTTP $HTTP after recover"; exit 1; }

# ── Log shipping ───────────────────────────────────────────────────────────────
info "Step 8: Log file exists"
sleep 2
[[ -f "$ROOT_DIR/logs/$ENV_ID/app.log" ]] && green "  app.log exists" || red "  WARN: app.log not found yet"

# ── Destroy ────────────────────────────────────────────────────────────────────
info "Step 9: Destroy environment"
bash "$PLATFORM/destroy_env.sh" "$ENV_ID"

[[ ! -f "$STATE" ]]                                           && green "  State file deleted" || red "  FAIL: state file still exists"
[[ -d "$ROOT_DIR/logs/archived/$ENV_ID" ]]                   && green "  Logs archived"      || red "  WARN: no archive directory"
! docker inspect "sandbox-app-$ENV_ID" > /dev/null 2>&1      && green "  Container removed"  || red "  FAIL: container still exists"
[[ ! -f "$ROOT_DIR/nginx/conf.d/$ENV_ID.conf" ]]             && green "  Nginx config gone"  || red "  FAIL: nginx config still present"

echo ""
echo "════════════════════════════════════════"
green " Lifecycle test complete"
echo "════════════════════════════════════════"
echo ""
