#!/usr/bin/env bash
# simulate_outage.sh — Inject failures into sandbox environments
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_ID=""
MODE=""

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_ID="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ -z "$ENV_ID" || -z "$MODE" ]]; then
  echo "Usage: $0 --env <env_id> --mode <crash|pause|network|recover|stress>"
  exit 1
fi

# === SAFETY GUARD ===
# Never simulate against infrastructure containers
PROTECTED_CONTAINERS=("sandbox-nginx" "sandbox-daemon" "sandbox-api" "sandbox-prometheus" "sandbox-grafana")
CONTAINER_NAME="sandbox-app-$ENV_ID"

for PROTECTED in "${PROTECTED_CONTAINERS[@]}"; do
  if [[ "$CONTAINER_NAME" == "$PROTECTED" ]]; then
    echo "🚫 SAFETY: Refusing to simulate outage on protected container: $CONTAINER_NAME"
    exit 1
  fi
done

# Also guard: if ENV_ID looks like an infrastructure name
if echo "$ENV_ID" | grep -qE "^(nginx|daemon|api|prometheus|grafana)$"; then
  echo "🚫 SAFETY: Refusing to simulate outage on infrastructure env: $ENV_ID"
  exit 1
fi

# Verify env exists
STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "❌ No state file found for $ENV_ID"
  exit 1
fi

# Get network name from state
NETWORK_NAME=$(python3 -c "import json; d=json.load(open('$STATE_FILE')); print(d.get('network',''))" 2>/dev/null || echo "sandbox-net-$ENV_ID")

echo "🔥 Simulating outage: mode=$MODE env=$ENV_ID container=$CONTAINER_NAME"

case "$MODE" in
  crash)
    echo "💀 CRASH: Killing container $CONTAINER_NAME"
    docker kill "$CONTAINER_NAME" 2>/dev/null || echo "⚠️  Container may already be dead"
    echo "   Health monitor should detect within 90s"
    ;;

  pause)
    echo "⏸️  PAUSE: Freezing container $CONTAINER_NAME"
    docker pause "$CONTAINER_NAME"
    echo "   Recover with: $0 --env $ENV_ID --mode recover"
    ;;

  network)
    echo "🔌 NETWORK: Disconnecting $CONTAINER_NAME from $NETWORK_NAME"
    docker network disconnect "$NETWORK_NAME" "$CONTAINER_NAME" 2>/dev/null || true
    # Also disconnect from nginx net
    docker network disconnect sandbox-nginx-net "$CONTAINER_NAME" 2>/dev/null || true
    echo "   Container is network-isolated. Recover with: $0 --env $ENV_ID --mode recover"
    ;;

  recover)
    echo "🔧 RECOVER: Attempting to restore $ENV_ID..."
    CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || echo "not_found")
    
    case "$CONTAINER_STATUS" in
      paused)
        docker unpause "$CONTAINER_NAME"
        echo "✅ Container unpaused"
        ;;
      exited|dead)
        docker start "$CONTAINER_NAME"
        echo "✅ Container restarted"
        ;;
      running)
        # Maybe network was disconnected — reconnect
        docker network connect "$NETWORK_NAME" "$CONTAINER_NAME" 2>/dev/null || true
        docker network connect sandbox-nginx-net "$CONTAINER_NAME" 2>/dev/null || true
        echo "✅ Network reconnected"
        ;;
      not_found)
        echo "❌ Container not found — cannot recover"
        exit 1
        ;;
      *)
        echo "   Container status: $CONTAINER_STATUS — no action taken"
        ;;
    esac
    
    # Update state
    python3 -c "
import json, sys
with open('$STATE_FILE') as f:
    d = json.load(f)
d['status'] = 'running'
import tempfile, os
tmp = '$STATE_FILE.tmp'
with open(tmp,'w') as f:
    json.dump(d, f, indent=2)
os.rename(tmp, '$STATE_FILE')
"
    echo "✅ Status reset to 'running'"
    ;;

  stress)
    echo "🔥 STRESS: Spiking CPU in $CONTAINER_NAME"
    if docker exec "$CONTAINER_NAME" which stress-ng 2>/dev/null; then
      docker exec -d "$CONTAINER_NAME" stress-ng --cpu 2 --timeout 60s
      echo "   CPU stress running for 60s"
    else
      # Fallback: Python-based CPU burner
      docker exec -d "$CONTAINER_NAME" sh -c 'python3 -c "
import time, threading
def burn():
    end = time.time() + 60
    while time.time() < end:
        x = sum(i*i for i in range(10000))
threads = [threading.Thread(target=burn) for _ in range(2)]
[t.start() for t in threads]
[t.join() for t in threads]
" &'
      echo "   Python CPU burner running for 60s (2 threads)"
    fi
    ;;

  *)
    echo "❌ Unknown mode: $MODE"
    echo "   Valid modes: crash, pause, network, recover, stress"
    exit 1
    ;;
esac

echo ""
echo "✅ Outage simulation ($MODE) applied to $ENV_ID"
