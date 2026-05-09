#!/usr/bin/env bash
# tests/test_api.sh — Integration test suite for the devops-sandbox API
# Run after `make up`. Each test prints PASS or FAIL.
set -euo pipefail

API="http://localhost:${API_PORT:-7000}"
PASS=0
FAIL=0
ENV_ID=""

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }

assert_eq() {
  local desc="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    green "  PASS: $desc"
    PASS=$(( PASS + 1 ))
  else
    red   "  FAIL: $desc (got='$got' want='$want')"
    FAIL=$(( FAIL + 1 ))
  fi
}

assert_contains() {
  local desc="$1" body="$2" substr="$3"
  if echo "$body" | grep -q "$substr"; then
    green "  PASS: $desc"
    PASS=$(( PASS + 1 ))
  else
    red   "  FAIL: $desc (expected '$substr' in response)"
    FAIL=$(( FAIL + 1 ))
  fi
}

assert_http() {
  local desc="$1" url="$2" method="${3:-GET}" data="${4:-}"
  local code
  if [[ -n "$data" ]]; then
    code=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "$url" \
      -H 'Content-Type: application/json' -d "$data")
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "$url")
  fi
  echo "    HTTP $code ← $method $url"
  echo "$code"
}

echo ""
echo "════════════════════════════════════════"
echo " devops-sandbox API Integration Tests"
echo " Target: $API"
echo "════════════════════════════════════════"
echo ""

# ── Test 1: API health ───────────────────────────────────────────────────────
echo "▶ 1. API self-health"
BODY=$(curl -sf "$API/health")
assert_contains "status=ok" "$BODY" '"status": "ok"'

# ── Test 2: Empty env list ───────────────────────────────────────────────────
echo "▶ 2. List envs (initially empty or existing)"
BODY=$(curl -sf "$API/envs")
assert_contains "response is JSON array" "$BODY" '['

# ── Test 3: Create environment ───────────────────────────────────────────────
echo "▶ 3. Create environment"
BODY=$(curl -sf -X POST "$API/envs" \
  -H 'Content-Type: application/json' \
  -d '{"name":"test-env","ttl":600}')
ENV_ID=$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
assert_contains "id field present"     "$BODY" '"id":'
assert_contains "name field present"   "$BODY" '"name":'
assert_contains "status=running"       "$BODY" '"status":'

if [[ -z "$ENV_ID" ]]; then
  red "  FAIL: Could not extract env ID — skipping remaining tests"
  FAIL=$(( FAIL + 1 ))
else
  green "  Created: $ENV_ID"

  # ── Test 4: Get single env ─────────────────────────────────────────────────
  echo "▶ 4. Get single environment"
  BODY=$(curl -sf "$API/envs/$ENV_ID")
  assert_eq "id matches" \
    "$(echo "$BODY" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")" \
    "$ENV_ID"

  # ── Test 5: List includes new env ─────────────────────────────────────────
  echo "▶ 5. List includes new env"
  BODY=$(curl -sf "$API/envs")
  assert_contains "env appears in list" "$BODY" "$ENV_ID"

  # ── Test 6: TTL remaining field ────────────────────────────────────────────
  echo "▶ 6. TTL remaining field"
  TTL_REM=$(curl -sf "$API/envs/$ENV_ID" | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('ttl_remaining',-1))")
  if [[ "$TTL_REM" -gt 0 ]]; then
    green "  PASS: ttl_remaining=$TTL_REM"
    PASS=$(( PASS + 1 ))
  else
    red "  FAIL: ttl_remaining=$TTL_REM (expected >0)"
    FAIL=$(( FAIL + 1 ))
  fi

  # ── Test 7: Logs endpoint ─────────────────────────────────────────────────
  echo "▶ 7. Logs endpoint"
  sleep 2
  BODY=$(curl -sf "$API/envs/$ENV_ID/logs")
  assert_contains "logs response has lines field" "$BODY" '"lines"'

  # ── Test 8: Health endpoint ───────────────────────────────────────────────
  echo "▶ 8. Health endpoint"
  BODY=$(curl -sf "$API/envs/$ENV_ID/health")
  assert_contains "health response has env_id" "$BODY" '"env_id"'
  assert_contains "health response has checks"  "$BODY" '"checks"'

  # ── Test 9: Invalid outage mode ───────────────────────────────────────────
  echo "▶ 9. Invalid outage mode rejected"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/envs/$ENV_ID/outage" \
    -H 'Content-Type: application/json' -d '{"mode":"explode"}')
  assert_eq "400 for unknown mode" "$CODE" "400"

  # ── Test 10: 404 for unknown env ──────────────────────────────────────────
  echo "▶ 10. 404 for unknown environment"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "$API/envs/env-does-not-exist")
  assert_eq "404 for unknown env" "$CODE" "404"

  # ── Test 11: Destroy environment ──────────────────────────────────────────
  echo "▶ 11. Destroy environment"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$API/envs/$ENV_ID")
  assert_eq "200 on destroy" "$CODE" "200"

  sleep 2

  # ── Test 12: Gone after destroy ───────────────────────────────────────────
  echo "▶ 12. Environment gone after destroy"
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "$API/envs/$ENV_ID")
  assert_eq "404 after destroy" "$CODE" "404"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
TOTAL=$(( PASS + FAIL ))
if [[ $FAIL -eq 0 ]]; then
  green " All $TOTAL tests passed"
else
  red   " $FAIL/$TOTAL tests FAILED"
fi
echo "════════════════════════════════════════"
echo ""

exit $FAIL
