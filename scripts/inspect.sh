#!/usr/bin/env bash
# scripts/inspect.sh — Pretty-print runtime state for an environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ENV_ID="${1:-}"
if [[ -z "$ENV_ID" ]]; then
  echo "Usage: $0 <env_id>"
  echo ""
  echo "Active environments:"
  for f in "$ROOT_DIR"/envs/*.json; do
    [[ -f "$f" ]] || continue
    ID=$(basename "$f" .json)
    NAME=$(python3 -c "import json; print(json.load(open('$f')).get('name','?'))")
    STATUS=$(python3 -c "import json; print(json.load(open('$f')).get('status','?'))")
    echo "  $ID  name=$NAME  status=$STATUS"
  done
  exit 0
fi

STATE="$ROOT_DIR/envs/$ENV_ID.json"
[[ -f "$STATE" ]] || { echo "No state file for $ENV_ID"; exit 1; }

echo "════════════════════════════════════════"
echo " Environment: $ENV_ID"
echo "════════════════════════════════════════"

python3 - "$STATE" <<'PYEOF'
import json, sys, time

with open(sys.argv[1]) as f:
    d = json.load(f)

now = time.time()
remaining = max(0, d['created_at_epoch'] + d['ttl'] - now)

print(f"  Name       : {d['name']}")
print(f"  ID         : {d['id']}")
print(f"  Status     : {d['status']}")
print(f"  Created    : {d['created_at']}")
print(f"  TTL        : {d['ttl']}s ({d['ttl']//60}m)")
print(f"  Remaining  : {int(remaining)}s ({int(remaining)//60}m)")
print(f"  Port       : {d['port']}")
print(f"  Network    : {d['network']}")
print(f"  Log PID    : {d.get('log_pid','—')}")
PYEOF

echo ""
echo "Container:"
docker inspect --format \
  "  Status: {{.State.Status}}  Started: {{.State.StartedAt}}" \
  "sandbox-app-$ENV_ID" 2>/dev/null || echo "  (container not found)"

echo ""
echo "Last health check:"
HLOG="$ROOT_DIR/logs/$ENV_ID/health.log"
if [[ -f "$HLOG" ]]; then
  tail -1 "$HLOG" | python3 -c "
import json,sys
d = json.loads(sys.stdin.read())
print(f\"  {d.get('ts','?')}  status={d.get('status','?')}  http={d.get('http_status','?')}  latency={d.get('latency_ms','?')}ms\")
" 2>/dev/null || tail -1 "$HLOG"
else
  echo "  (no health log yet)"
fi

echo ""
echo "Nginx config:"
NCONF="$ROOT_DIR/nginx/conf.d/$ENV_ID.conf"
if [[ -f "$NCONF" ]]; then
  echo "  $NCONF (exists)"
else
  echo "  (no nginx config)"
fi

echo "════════════════════════════════════════"
