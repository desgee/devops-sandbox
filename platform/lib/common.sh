#!/usr/bin/env bash
# platform/lib/common.sh
# Shared utility functions sourced by create_env.sh, destroy_env.sh, etc.
# Do NOT execute directly.

# ── Logging ──────────────────────────────────────────────────────────────────

ts()  { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
log() { echo "[$(ts)] $*"; }

log_info()  { echo "$(ts) [INFO]  $*"; }
log_warn()  { echo "$(ts) [WARN]  $*" >&2; }
log_error() { echo "$(ts) [ERROR] $*" >&2; }

# ── State file helpers ────────────────────────────────────────────────────────

# state_get <env_id> <key>
# Read a single key from envs/<env_id>.json
state_get() {
  local env_id="$1" key="$2"
  local state_file="${ROOT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}/envs/$env_id.json"
  [[ -f "$state_file" ]] || { log_error "No state file for $env_id"; return 1; }
  python3 -c "import json,sys; d=json.load(open('$state_file')); print(d.get('$key',''))"
}

# state_set <env_id> <key> <value>
# Atomically update a single key in envs/<env_id>.json
state_set() {
  local env_id="$1" key="$2" value="$3"
  local state_file="${ROOT_DIR:-$(pwd)}/envs/$env_id.json"
  [[ -f "$state_file" ]] || { log_error "No state file for $env_id"; return 1; }
  local tmp
  tmp=$(mktemp)
  python3 - "$state_file" "$key" "$value" "$tmp" <<'PYEOF'
import json, sys
path, key, value, out = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path) as f:
    d = json.load(f)
# Try int/float coercion; fall back to string
try:    d[key] = int(value)
except: 
    try:    d[key] = float(value)
    except: d[key] = value
with open(out, 'w') as f:
    json.dump(d, f, indent=2)
PYEOF
  mv "$tmp" "$state_file"
}

# ── Docker helpers ────────────────────────────────────────────────────────────

# container_status <name>
# Returns: running | paused | exited | dead | not_found
container_status() {
  local name="$1"
  docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "not_found"
}

# container_exists <name>
container_exists() {
  docker inspect "$1" > /dev/null 2>&1
}

# network_exists <name>
network_exists() {
  docker network ls --format '{{.Name}}' | grep -q "^$1$"
}

# ── Port helpers ──────────────────────────────────────────────────────────────

# free_port <min> <max>
# Returns a random free port in [min, max]
free_port() {
  local min="${1:-8100}" max="${2:-9000}"
  local port
  while true; do
    port=$(shuf -i "${min}-${max}" -n 1)
    # Check if port is already bound
    if ! ss -tlnp 2>/dev/null | grep -q ":$port " && \
       ! docker ps --format '{{.Ports}}' | grep -q ":$port->"; then
      echo "$port"
      return
    fi
  done
}

# ── Nginx helpers ─────────────────────────────────────────────────────────────

nginx_reload() {
  if docker ps --format '{{.Names}}' | grep -q "^sandbox-nginx$"; then
    docker exec sandbox-nginx nginx -s reload 2>/dev/null && return 0
    log_warn "Nginx reload failed — trying test first"
    docker exec sandbox-nginx nginx -t 2>&1 | head -5
    return 1
  else
    log_warn "sandbox-nginx container not running — skipping reload"
    return 0
  fi
}

# ── Validation ────────────────────────────────────────────────────────────────

# is_protected_container <name>
# Returns 0 (true) if the name matches infrastructure containers
is_protected_container() {
  local name="$1"
  local protected=("sandbox-nginx" "sandbox-daemon" "sandbox-api" "sandbox-monitor" "sandbox-prometheus" "sandbox-grafana" "sandbox-cadvisor")
  for p in "${protected[@]}"; do
    [[ "$name" == "$p" ]] && return 0
  done
  return 1
}

# require_env_id <env_id>
# Exits 1 if env_id is empty or state file does not exist
require_env_id() {
  local env_id="${1:-}"
  if [[ -z "$env_id" ]]; then
    log_error "ENV_ID is required"
    return 1
  fi
  local state_file="${ROOT_DIR:-$(pwd)}/envs/$env_id.json"
  if [[ ! -f "$state_file" ]]; then
    log_error "No state file found for $env_id"
    return 1
  fi
  return 0
}
