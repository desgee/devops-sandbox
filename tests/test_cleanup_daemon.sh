#!/usr/bin/env bash
# tests/test_cleanup_daemon.sh
# Verifies the cleanup daemon destroys an env after its TTL expires.
# Uses a very short TTL (10s) and polls for destruction.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM="$ROOT_DIR/platform"

green() { printf '\033[0;32mPASS: %s\033[0m\n' "$*"; }
red()   { printf '\033[0;31mFAIL: %s\033[0m\n' "$*"; exit 1; }
info()  { printf '\033[0;34m▶ %s\033[0m\n' "$*"; }

echo ""
echo "════════════════════════════════════════"
echo " devops-sandbox — Cleanup Daemon Test"
echo "════════════════════════════════════════"
echo ""

# ── Verify daemon is running ──────────────────────────────────────────────────
info "1. Check cleanup daemon is running"
if docker ps --format '{{.Names}}' | grep -q "^sandbox-daemon$"; then
  green "sandbox-daemon container is running"
else
  red "sandbox-daemon is NOT running — run 'make up' first"
fi

# ── Create short-lived env ────────────────────────────────────────────────────
info "2. Create environment with 10s TTL"
bash "$PLATFORM/create_env.sh" "ttl-test" 10 > /dev/null
ENV_ID=$(ls "$ROOT_DIR/envs/" | grep '^env-' | sort -t- -k2 -n | tail -1 | sed 's/\.json//')
echo "   Created: $ENV_ID"
green "Env created with 10s TTL"

# ── Wait for daemon to pick it up (max 130s: 10s TTL + up to 2x 60s daemon cycles) ─
info "3. Waiting for daemon to destroy (TTL=10s, daemon polls every 60s)..."
echo "   Max wait: 130s"
DESTROYED=0
for i in $(seq 1 130); do
  if [[ ! -f "$ROOT_DIR/envs/$ENV_ID.json" ]]; then
    DESTROYED=1
    echo "   Destroyed after ${i}s"
    break
  fi
  sleep 1
  [[ $((i % 10)) -eq 0 ]] && echo "   ...${i}s elapsed"
done

if [[ $DESTROYED -eq 1 ]]; then
  green "Daemon auto-destroyed expired env"
else
  red "Daemon did NOT destroy env within 130s"
fi

# ── Verify cleanup log ────────────────────────────────────────────────────────
info "4. Verify cleanup.log entry"
if grep -q "$ENV_ID" "$ROOT_DIR/logs/cleanup.log" 2>/dev/null; then
  green "Cleanup log contains entry for $ENV_ID"
else
  red "Cleanup log missing entry for $ENV_ID"
fi

# ── Verify archive ────────────────────────────────────────────────────────────
info "5. Verify logs archived"
if [[ -d "$ROOT_DIR/logs/archived/$ENV_ID" ]]; then
  green "Logs archived to logs/archived/$ENV_ID"
else
  red "Archive directory not found for $ENV_ID"
fi

echo ""
echo "════════════════════════════════════════"
printf '\033[0;32m Cleanup daemon test complete\033[0m\n'
echo "════════════════════════════════════════"
echo ""
