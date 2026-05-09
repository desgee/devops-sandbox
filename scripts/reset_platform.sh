#!/usr/bin/env bash
# scripts/reset_platform.sh — Hard reset: stop everything and wipe all state
# Use when make clean isn't enough (e.g. containers stuck in bad state)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "⚠️  HARD RESET: This will destroy ALL sandbox containers, networks, and state."
read -rp "Type 'yes' to confirm: " CONFIRM
[[ "$CONFIRM" == "yes" ]] || { echo "Aborted."; exit 0; }

echo ""
echo "🛑 Stopping all sandbox app containers..."
CONTAINERS=$(docker ps -aq --filter 'label=sandbox.env' 2>/dev/null || echo "")
if [[ -n "$CONTAINERS" ]]; then
  # shellcheck disable=SC2086
  docker rm -f $CONTAINERS
  echo "   Removed $(echo "$CONTAINERS" | wc -w) containers"
else
  echo "   (none found)"
fi

echo "🌐 Removing all sandbox networks..."
NETS=$(docker network ls -q --filter 'label=sandbox.env' 2>/dev/null || echo "")
if [[ -n "$NETS" ]]; then
  # shellcheck disable=SC2086
  docker network rm $NETS 2>/dev/null || true
fi

echo "📦 Stopping infrastructure (docker compose down)..."
cd "$ROOT_DIR" && docker compose down --remove-orphans 2>/dev/null || true

echo "🗑️  Wiping state files..."
rm -f "$ROOT_DIR"/envs/*.json
rm -f "$ROOT_DIR"/nginx/conf.d/env-*.conf

echo "📋 Wiping logs..."
rm -rf "$ROOT_DIR"/logs/archived/*/
find "$ROOT_DIR/logs" -name "*.log" -delete 2>/dev/null || true
find "$ROOT_DIR/logs" -name "*.pid"  -delete 2>/dev/null || true

echo ""
echo "✅ Platform reset complete. Run 'make up' to start fresh."
