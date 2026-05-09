#!/usr/bin/env bash
# scripts/export_logs.sh — Export all logs for an environment as a .tar.gz
# Usage: ./scripts/export_logs.sh <env_id> [output_dir]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_ID="${1:-}"
OUTPUT_DIR="${2:-$ROOT_DIR}"

if [[ -z "$ENV_ID" ]]; then
  echo "Usage: $0 <env_id> [output_dir]"
  exit 1
fi

# Look in active logs first, then archived
LOG_SRC="$ROOT_DIR/logs/$ENV_ID"
if [[ ! -d "$LOG_SRC" ]]; then
  LOG_SRC="$ROOT_DIR/logs/archived/$ENV_ID"
fi

if [[ ! -d "$LOG_SRC" ]]; then
  echo "❌ No logs found for $ENV_ID"
  exit 1
fi

ARCHIVE="$OUTPUT_DIR/${ENV_ID}-logs-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$LOG_SRC")" "$(basename "$LOG_SRC")"

echo "✅ Logs exported: $ARCHIVE ($(du -sh "$ARCHIVE" | cut -f1))"
