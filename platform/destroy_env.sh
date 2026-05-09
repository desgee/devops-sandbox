#!/usr/bin/env bash
# destroy_env.sh — Tear down a sandbox environment cleanly
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_ID="${1:-}"
if [[ -z "$ENV_ID" ]]; then
  echo "Usage: $0 <env_id>"
  exit 1
fi

STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
if [[ ! -f "$STATE_FILE" ]]; then
  echo "⚠️  State file not found for $ENV_ID — attempting best-effort cleanup"
fi

echo "💥 Destroying environment: $ENV_ID"

# Read state if available
NETWORK_NAME=""
LOG_PID=""
if [[ -f "$STATE_FILE" ]]; then
  NETWORK_NAME=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('network',''))" 2>/dev/null || echo "")
  LOG_PID=$(python3 -c "import json,sys; d=json.load(open('$STATE_FILE')); print(d.get('log_pid',''))" 2>/dev/null || echo "")
fi
NETWORK_NAME="${NETWORK_NAME:-sandbox-net-$ENV_ID}"

# Kill log shipper process
PID_FILE="$ROOT_DIR/logs/$ENV_ID/log_shipper.pid"
if [[ -f "$PID_FILE" ]]; then
  SAVED_PID=$(cat "$PID_FILE")
  if kill -0 "$SAVED_PID" 2>/dev/null; then
    kill "$SAVED_PID" 2>/dev/null && echo "✅ Log shipper killed (PID: $SAVED_PID)"
  fi
  rm -f "$PID_FILE"
elif [[ -n "$LOG_PID" ]]; then
  if kill -0 "$LOG_PID" 2>/dev/null; then
    kill "$LOG_PID" 2>/dev/null && echo "✅ Log shipper killed (PID: $LOG_PID)"
  fi
fi

# Stop & remove all labeled containers
echo "🛑 Stopping containers labeled sandbox.env=$ENV_ID"
CONTAINERS=$(docker ps -aq --filter "label=sandbox.env=$ENV_ID" 2>/dev/null || echo "")
if [[ -n "$CONTAINERS" ]]; then
  docker stop $CONTAINERS 2>/dev/null || true
  docker rm -f $CONTAINERS 2>/dev/null || true
  echo "✅ Containers removed"
else
  echo "   (no containers found)"
fi

# Remove Docker network
if docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
  docker network rm "$NETWORK_NAME" 2>/dev/null && echo "✅ Network removed: $NETWORK_NAME"
fi

# Delete Nginx config and reload
NGINX_CONF="$ROOT_DIR/nginx/conf.d/$ENV_ID.conf"
if [[ -f "$NGINX_CONF" ]]; then
  rm -f "$NGINX_CONF"
  echo "✅ Nginx config deleted"
  if docker ps --format '{{.Names}}' | grep -q "^sandbox-nginx$"; then
    docker exec sandbox-nginx nginx -s reload 2>/dev/null && echo "✅ Nginx reloaded"
  fi
fi

# Archive logs
LOG_DIR="$ROOT_DIR/logs/$ENV_ID"
ARCHIVE_DIR="$ROOT_DIR/logs/archived/$ENV_ID"
if [[ -d "$LOG_DIR" ]]; then
  mkdir -p "$ARCHIVE_DIR"
  cp -r "$LOG_DIR/." "$ARCHIVE_DIR/" 2>/dev/null || true
  rm -rf "$LOG_DIR"
  echo "✅ Logs archived to $ARCHIVE_DIR"
fi

# Delete state file
if [[ -f "$STATE_FILE" ]]; then
  rm -f "$STATE_FILE"
  echo "✅ State file deleted"
fi

echo ""
echo "✅ Environment $ENV_ID destroyed successfully."
