#!/usr/bin/env bash
# scripts/prune_archives.sh — Remove archived logs older than N days (default: 7)
# Usage: ./scripts/prune_archives.sh [days]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DAYS="${1:-7}"
ARCHIVE_DIR="$ROOT_DIR/logs/archived"

echo "🧹 Pruning archives older than ${DAYS} days from $ARCHIVE_DIR"

if [[ ! -d "$ARCHIVE_DIR" ]]; then
  echo "   Archive directory does not exist — nothing to prune"
  exit 0
fi

COUNT=0
find "$ARCHIVE_DIR" -maxdepth 1 -mindepth 1 -type d -mtime "+$DAYS" | while read -r dir; do
  echo "   Removing: $(basename "$dir") (modified $(stat -c %y "$dir" | cut -d' ' -f1))"
  rm -rf "$dir"
  COUNT=$((COUNT + 1))
done

echo "✅ Pruning complete"
