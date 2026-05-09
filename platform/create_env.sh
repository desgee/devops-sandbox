#!/usr/bin/env bash
# create_env.sh — Spin up an isolated sandbox environment
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

source "$ROOT_DIR/.env" 2>/dev/null || true

ENV_NAME="${1:-}"
TTL="${2:-1800}"  # default 30 minutes

if [[ -z "$ENV_NAME" ]]; then
  echo "Usage: $0 <name> [ttl_seconds]"
  exit 1
fi

# Sanitize name
ENV_NAME=$(echo "$ENV_NAME" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g')

# Generate unique env ID
ENV_ID="env-$(date +%s)-$(head /dev/urandom | tr -dc 'a-z0-9' | head -c 6)"
CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
CREATED_AT_EPOCH=$(date +%s)
PORT=$(shuf -i 8100-9000 -n 1)

# Ensure no port collision
while docker ps --format '{{.Ports}}' | grep -q ":$PORT->"; do
  PORT=$(shuf -i 8100-9000 -n 1)
done

echo "🚀 Creating environment: $ENV_NAME ($ENV_ID)"
echo "   TTL: ${TTL}s | Port: $PORT"

# Create dedicated Docker network
NETWORK_NAME="sandbox-net-$ENV_ID"
docker network create "$NETWORK_NAME" --label "sandbox.env=$ENV_ID" > /dev/null
echo "✅ Network created: $NETWORK_NAME"

# Create per-env log directory
mkdir -p "$ROOT_DIR/logs/$ENV_ID"

# Start the demo app container
CONTAINER_ID=$(docker run -d \
  --name "sandbox-app-$ENV_ID" \
  --network "$NETWORK_NAME" \
  --label "sandbox.env=$ENV_ID" \
  --label "sandbox.name=$ENV_NAME" \
  --label "sandbox.type=app" \
  -p "$PORT:5000" \
  -e ENV_ID="$ENV_ID" \
  -e ENV_NAME="$ENV_NAME" \
  "sandbox-demo-app:latest" 2>/dev/null || \
  docker run -d \
    --name "sandbox-app-$ENV_ID" \
    --network "$NETWORK_NAME" \
    --label "sandbox.env=$ENV_ID" \
    --label "sandbox.name=$ENV_NAME" \
    --label "sandbox.type=app" \
    -p "$PORT:5000" \
    -e ENV_ID="$ENV_ID" \
    -e ENV_NAME="$ENV_NAME" \
    python:3.11-slim \
    python3 -c "
import http.server, os, json, time

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        env_id = os.environ.get('ENV_ID','unknown')
        env_name = os.environ.get('ENV_NAME','unknown')
        if self.path == '/health':
            body = json.dumps({'status':'ok','env_id':env_id,'env_name':env_name,'ts':time.time()}).encode()
            self.send_response(200)
        else:
            body = f'<h1>Sandbox: {env_name}</h1><p>ID: {env_id}</p><a href=\"/health\">/health</a>'.encode()
            self.send_response(200)
        self.send_header('Content-Type','application/json' if self.path=='/health' else 'text/html')
        self.end_headers()
        self.wfile.write(body)

http.server.HTTPServer(('0.0.0.0',5000),H).serve_forever()
")
echo "✅ App container started: $CONTAINER_ID"

# Connect to nginx network so nginx can proxy to it
if docker network ls --format '{{.Name}}' | grep -q "^sandbox-nginx-net$"; then
  docker network connect sandbox-nginx-net "sandbox-app-$ENV_ID" 2>/dev/null || true
fi

# Log shipping: Approach A — docker logs fan-out
mkdir -p "$ROOT_DIR/logs/$ENV_ID"
nohup docker logs -f "sandbox-app-$ENV_ID" >> "$ROOT_DIR/logs/$ENV_ID/app.log" 2>&1 &
LOG_PID=$!
echo "$LOG_PID" > "$ROOT_DIR/logs/$ENV_ID/log_shipper.pid"
echo "✅ Log shipper started (PID: $LOG_PID)"

# Write Nginx config
NGINX_CONF="$ROOT_DIR/nginx/conf.d/$ENV_ID.conf"
cat > "$NGINX_CONF" <<NGINXCONF
# Auto-generated for $ENV_ID ($ENV_NAME)
upstream $ENV_ID {
    server sandbox-app-$ENV_ID:5000;
}

server {
    listen 80;
    server_name $ENV_ID.sandbox.local;

    location / {
        proxy_pass http://$ENV_ID;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Env-ID $ENV_ID;
        add_header X-Sandbox-Env "$ENV_ID";
    }
}
NGINXCONF
echo "✅ Nginx config written: $NGINX_CONF"

# Reload Nginx
if docker ps --format '{{.Names}}' | grep -q "^sandbox-nginx$"; then
  docker exec sandbox-nginx nginx -s reload 2>/dev/null && echo "✅ Nginx reloaded"
fi

# Write state file atomically
STATE_FILE="$ROOT_DIR/envs/$ENV_ID.json"
TEMP_STATE=$(mktemp)
cat > "$TEMP_STATE" <<JSON
{
  "id": "$ENV_ID",
  "name": "$ENV_NAME",
  "created_at": "$CREATED_AT",
  "created_at_epoch": $CREATED_AT_EPOCH,
  "ttl": $TTL,
  "port": $PORT,
  "container_id": "$CONTAINER_ID",
  "network": "$NETWORK_NAME",
  "status": "running",
  "log_pid": $LOG_PID
}
JSON
mv "$TEMP_STATE" "$STATE_FILE"
echo "✅ State file written: $STATE_FILE"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Environment Ready!                      ║"
echo "║  ID:   $ENV_ID"
echo "║  URL:  http://localhost:$PORT"
echo "║  TTL:  ${TTL}s (expires in $(( TTL / 60 )) min)"
echo "╚══════════════════════════════════════════╝"
