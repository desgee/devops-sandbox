#!/usr/bin/env bash
# scripts/list_envs.sh — Print a formatted table of all active environments
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

shopt -s nullglob
FILES=("$ROOT_DIR"/envs/*.json)
shopt -u nullglob

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No active environments."
  exit 0
fi

printf "%-30s %-14s %-10s %-8s %-12s %s\n" \
  "ID" "NAME" "STATUS" "PORT" "REMAINING" "CREATED"
printf '%s\n' "$(python3 -c "print('-'*100)")"

NOW=$(date +%s)

for f in "${FILES[@]}"; do
  python3 - "$f" "$NOW" <<'PYEOF'
import json, sys, time

with open(sys.argv[1]) as f:
    d = json.load(f)

now = int(sys.argv[2])
remaining = max(0, d['created_at_epoch'] + d['ttl'] - now)
rem_str = f"{remaining//60}m{remaining%60:02d}s"

print(f"{d['id']:<30} {d['name']:<14} {d['status']:<10} {d['port']:<8} {rem_str:<12} {d['created_at']}")
PYEOF
done
