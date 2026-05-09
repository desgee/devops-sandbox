#!/usr/bin/env bash
# cleanup_daemon.sh — Auto-destroy expired sandbox environments
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

LOG_FILE="$ROOT_DIR/logs/cleanup.log"
mkdir -p "$ROOT_DIR/logs"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
  echo "[$(ts)] $*" | tee -a "$LOG_FILE"
}

log "🟢 Cleanup daemon started (PID: $$)"

while true; do
  NOW=$(date +%s)

  # Find all state files
  shopt -s nullglob
  STATE_FILES=("$ROOT_DIR/envs/"*.json)
  shopt -u nullglob

  if [[ ${#STATE_FILES[@]} -eq 0 ]]; then
    log "   No active environments."
  else
    for STATE_FILE in "${STATE_FILES[@]}"; do
      ENV_ID=$(basename "$STATE_FILE" .json)

      # Parse created_at_epoch and ttl safely
      CREATED_EPOCH=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['created_at_epoch'])" 2>/dev/null || echo "0")
      TTL=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d['ttl'])" 2>/dev/null || echo "1800")
      STATUS=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('status','unknown'))" 2>/dev/null || echo "unknown")
      NAME=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('name','unknown'))" 2>/dev/null || echo "unknown")

      EXPIRES_AT=$(( CREATED_EPOCH + TTL ))
      REMAINING=$(( EXPIRES_AT - NOW ))

      if [[ $NOW -ge $EXPIRES_AT ]]; then
        log "⏰ TTL expired for $ENV_ID ($NAME) — destroying..."
        if bash "$SCRIPT_DIR/destroy_env.sh" "$ENV_ID" >> "$LOG_FILE" 2>&1; then
          log "✅ Destroyed $ENV_ID successfully"
        else
          log "❌ Failed to destroy $ENV_ID"
        fi
      else
        log "   $ENV_ID ($NAME): status=$STATUS, expires in ${REMAINING}s"
      fi
    done
  fi

  log "   Sleeping 60s..."
  sleep 60
done
