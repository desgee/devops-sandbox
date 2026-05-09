#!/usr/bin/env bash
# tests/test_outage.sh — Test all outage simulation modes
# Requires: platform up, demo app image built
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM="$ROOT_DIR/platform"

PASS=0; FAIL=0

green() { printf '\033[0;32mPASS: %s\033[0m\n' "$*"; PASS=$((PASS+1)); }
red()   { printf '\033[0;31mFAIL: %s\033[0m\n' "$*"; FAIL=$((FAIL+1)); }
info()  { printf '\033[0;34m▶ %s\033[0m\n' "$*"; }

echo ""
echo "════════════════════════════════════════"
echo " devops-sandbox — Outage Simulation Tests"
echo "════════════════════════════════════════"
echo ""

# Helper: create a fresh environment
create_test_env() {
  bash "$PLATFORM/create_env.sh" "outage-test" 300 > /dev/null 2>&1
  ls "$ROOT_DIR/envs/" | grep '^env-' | sort -t- -k2 -n | tail -1 | sed 's/\.json//'
}

wait_for_http() {
  local port="$1" retries=10
  for _ in $(seq 1 $retries); do
    curl -sf "http://localhost:$port/health" > /dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

# ── Guard: refuse infra containers ───────────────────────────────────────────
info "1. Safety guard — refuse infra targets"
if bash "$PLATFORM/simulate_outage.sh" --env nginx --mode crash 2>&1 | grep -q "SAFETY"; then
  green "Safety guard fires on 'nginx'"
else
  red "Safety guard did not fire on 'nginx'"
fi

# ── Create test env ───────────────────────────────────────────────────────────
info "2. Creating test environment"
ENV_ID=$(create_test_env)
PORT=$(python3 -c "import json; print(json.load(open('$ROOT_DIR/envs/$ENV_ID.json'))['port'])")
echo "   ENV_ID=$ENV_ID  PORT=$PORT"
sleep 2

if wait_for_http "$PORT"; then
  green "App reachable before simulation"
else
  red "App not reachable — aborting outage tests"
  bash "$PLATFORM/destroy_env.sh" "$ENV_ID" > /dev/null 2>&1
  exit 1
fi

# ── Test: crash ──────────────────────────────────────────────────────────────
info "3. MODE=crash"
bash "$PLATFORM/simulate_outage.sh" --env "$ENV_ID" --mode crash > /dev/null
sleep 1
STATUS=$(docker inspect --format='{{.State.Status}}' "sandbox-app-$ENV_ID" 2>/dev/null || echo "not_found")
if [[ "$STATUS" != "running" ]]; then
  green "Container is $STATUS after crash"
else
  red "Container still running after crash"
fi

# Recover for next test
info "   Recovering..."
bash "$PLATFORM/simulate_outage.sh" --env "$ENV_ID" --mode recover > /dev/null
sleep 2
wait_for_http "$PORT" && green "Recovered from crash" || red "Did not recover from crash"

# ── Test: pause ───────────────────────────────────────────────────────────────
info "4. MODE=pause"
bash "$PLATFORM/simulate_outage.sh" --env "$ENV_ID" --mode pause > /dev/null
sleep 1
STATUS=$(docker inspect --format='{{.State.Status}}' "sandbox-app-$ENV_ID" 2>/dev/null)
[[ "$STATUS" == "paused" ]] && green "Container paused" || red "Container status=$STATUS (expected paused)"

info "   Recovering..."
bash "$PLATFORM/simulate_outage.sh" --env "$ENV_ID" --mode recover > /dev/null
sleep 2
wait_for_http "$PORT" && green "Recovered from pause" || red "Did not recover from pause"

# ── Test: network ─────────────────────────────────────────────────────────────
info "5. MODE=network"
bash "$PLATFORM/simulate_outage.sh" --env "$ENV_ID" --mode network > /dev/null
sleep 1
# Container should still be running but unreachable via host port
STATUS=$(docker inspect --format='{{.State.Status}}' "sandbox-app-$ENV_ID" 2>/dev/null)
[[ "$STATUS" == "running" ]] && green "Container still running (network isolated)" || red "Container not running after network mode (status=$STATUS)"

info "   Recovering..."
bash "$PLATFORM/simulate_outage.sh" --env "$ENV_ID" --mode recover > /dev/null
sleep 2
wait_for_http "$PORT" && green "Recovered from network isolation" || red "Did not recover from network isolation"

# ── Test: invalid env ─────────────────────────────────────────────────────────
info "6. Invalid env_id rejected"
if ! bash "$PLATFORM/simulate_outage.sh" --env "env-does-not-exist" --mode crash 2>&1 | grep -q "No state file\|not found"; then
  red "Should have rejected unknown env"
else
  green "Unknown env correctly rejected"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
info "7. Cleanup"
bash "$PLATFORM/destroy_env.sh" "$ENV_ID" > /dev/null
green "Test environment destroyed"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
TOTAL=$((PASS+FAIL))
if [[ $FAIL -eq 0 ]]; then
  printf '\033[0;32m All %d/%d tests passed\033[0m\n' "$PASS" "$TOTAL"
else
  printf '\033[0;31m %d/%d tests FAILED\033[0m\n' "$FAIL" "$TOTAL"
fi
echo "════════════════════════════════════════"
echo ""
exit $FAIL
