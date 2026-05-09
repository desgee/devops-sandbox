# devops-sandbox — Step-by-Step Setup Guide

From zero to a running chaos-engineering sandbox platform in minutes.  

---

## Contents

1. [Prerequisites](#1-prerequisites)
2. [Clone & Configure](#2-clone--configure)
3. [Build the Demo App Image](#3-build-the-demo-app-image)
4. [Start the Platform](#4-start-the-platform)
5. [Create Your First Environment](#5-create-your-first-environment)
6. [Inspect & List Environments](#6-inspect--list-environments)
7. [Monitor Health](#7-monitor-health)
8. [Simulate an Outage](#8-simulate-an-outage)
9. [Observe Degradation](#9-observe-degradation)
10. [View Logs](#10-view-logs)
11. [Recover](#11-recover)
12. [Optional — Netdata Dashboard](#12-optional--netdata-dashboard)
13. [Destroy an Environment](#13-destroy-an-environment)
14. [Watch Auto-Destroy via TTL](#14-watch-auto-destroy-via-ttl)
15. [Stop the Platform](#15-stop-the-platform)
16. [Full Wipe](#16-full-wipe)
17. [Running the Test Suite](#17-running-the-test-suite)
18. [Troubleshooting](#18-troubleshooting)

---

## 1. Prerequisites

### 1.1 Provision a Linux VM

Ubuntu 22.04 or 24.04 LTS recommended.  
Minimum spec: **2 vCPUs, 4 GB RAM, 20 GB disk.**

Works on a local VM (UTM, VirtualBox, VMware) or any cloud provider.

---

### 1.2 Install Docker Engine

```bash
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
newgrp docker
```

Verify:

```bash
docker --version          # Docker version 24.x or higher
docker compose version    # Docker Compose version 2.20+
```

---

### 1.3 Install Python 3.11+, Make, and Git

```bash
sudo apt update && sudo apt install -y python3.11 python3-pip make git
```

Verify:

```bash
python3 --version   # Python 3.11+
make --version
git --version
```

---

## 2. Clone & Configure

### 2.1 Clone the repository

```bash
git clone https://github.com/YOUR_USERNAME/devops-sandbox.git
cd devops-sandbox
```

Replace `YOUR_USERNAME` with your GitHub username. The repo must be **public** for review.

---

### 2.2 Create your `.env` file

```bash
cp .env.example .env
```

Open `.env` and confirm the defaults — or change ports if they conflict with something already running on your machine:

```bash
# Core ports
NGINX_PORT=8080
API_PORT=7000

# Port range for sandbox environments
ENV_PORT_MIN=8100
ENV_PORT_MAX=9000

# Optional Netdata monitoring
NETDATA_PORT=19999

# Cleanup daemon and health monitor intervals
CLEANUP_INTERVAL=60
HEALTH_POLL_INTERVAL=30
HEALTH_DEGRADED_THRESHOLD=3
```

> **Never commit `.env`** — it is already in `.gitignore`.

---

### 2.3 Make all scripts executable

```bash
chmod +x platform/*.sh scripts/*.sh tests/*.sh
```

---

### 2.4 Create required runtime directories

`make up` does this automatically, but you can also do it manually:

```bash
mkdir -p logs/archived envs nginx/conf.d
```

---

## 3. Build the Demo App Image

The platform needs `sandbox-demo-app:latest` available locally before any environment can be created.

```bash
make build-app
```

This builds `apps/demo/Dockerfile` and tags it `sandbox-demo-app:latest`.

Verify:

```bash
docker images sandbox-demo-app
```

You should see `sandbox-demo-app   latest` in the list.

---

## 4. Start the Platform

```bash
make up
```

This does four things in order:

1. Creates `logs/`, `envs/`, and `nginx/conf.d/` if they don't exist
2. Builds the API Docker image (`Dockerfile.api`)
3. Starts four containers via `docker-compose.yml`:

| Container | Role | Port |
|---|---|---|
| `sandbox-nginx` | Front door — routes traffic to env containers | 8080 |
| `sandbox-api` | REST control plane | 7000 |
| `sandbox-daemon` | TTL cleanup loop (checks every 60s) | — |
| `sandbox-monitor` | Health poller (polls every 30s) | — |

Expected output:

```
✅ Platform running:
   Nginx:  http://localhost:8080
   API:    http://localhost:7000

   Quick test: curl http://localhost:7000/envs
```

---

### 4.1 Verify all containers are healthy

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

All four containers should show `Up`.

---

### 4.2 Ping the API

```bash
curl -s http://localhost:7000/health | python3 -m json.tool
```

Expected:

```json
{
    "status": "ok",
    "service": "devops-sandbox-api"
}
```

---

### 4.3 Ping Nginx

```bash
curl -s http://localhost:8080/
```

Expected:

```json
{"service":"devops-sandbox","status":"ready","message":"Add Host header matching your env ID"}
```

---

## 5. Create Your First Environment

### Option A — Interactive via Make

```bash
make create
```

You are prompted for a name and TTL:

```
Environment name: myapp
TTL in seconds [1800]: 300
```

---

### Option B — Direct script

```bash
bash platform/create_env.sh myapp 300
```

---

### Option C — REST API

```bash
curl -s -X POST http://localhost:7000/envs \
  -H 'Content-Type: application/json' \
  -d '{"name":"myapp","ttl":300}' | python3 -m json.tool
```

---

### What `create_env.sh` does under the hood

1. Generates a unique `ENV_ID` (e.g. `env-1716000000-a1b2c3`)
2. Picks a random free port in the `8100–9000` range
3. Creates a dedicated Docker network (`sandbox-net-<ENV_ID>`)
4. Starts `sandbox-app-<ENV_ID>` container from `sandbox-demo-app:latest`
5. Connects the container to `sandbox-nginx-net` so Nginx can proxy to it
6. Starts a log shipper: `docker logs -f <container> >> logs/<ENV_ID>/app.log &` (PID saved)
7. Writes `nginx/conf.d/<ENV_ID>.conf` and reloads Nginx
8. Atomically writes `envs/<ENV_ID>.json` via `mktemp` + `mv`

---

### Expected output

```
╔══════════════════════════════════════════╗
║  Environment Ready!                      ║
║  ID:   env-1716000000-a1b2c3             ║
║  URL:  http://localhost:8412             ║
║  TTL:  300s (expires in 5 min)           ║
╚══════════════════════════════════════════╝
```

Note the `ID` and `port` — you'll need them for every subsequent command.

---

### 5.1 Test the app container directly

```bash
# Replace 8412 with your actual port
curl http://localhost:8412/
curl http://localhost:8412/health
curl http://localhost:8412/info
```

`/health` returns:

```json
{
    "status": "ok",
    "env_id": "env-1716000000-a1b2c3",
    "env_name": "myapp",
    "uptime_s": 3.1,
    "requests": 1,
    "hostname": "a1b2c3d4e5f6",
    "ts": "2025-01-01T12:00:03Z"
}
```

---

### 5.2 Verify the state file was written

```bash
cat envs/env-1716000000-a1b2c3.json | python3 -m json.tool
```

You should see all fields: `id`, `name`, `created_at`, `created_at_epoch`, `ttl`, `port`, `container_id`, `network`, `status`, `log_pid`.

---

## 6. Inspect & List Environments

### List all active environments (API)

```bash
make status
```

Or directly:

```bash
curl -s http://localhost:7000/envs | python3 -m json.tool
```

Each entry includes `ttl_remaining` — seconds until the daemon auto-destroys it.

---

### List all environments (table view)

```bash
bash scripts/list_envs.sh
```

Output:

```
ID                             NAME           STATUS     PORT     REMAINING    CREATED
----------------------------------------------------------------------------------------------------
env-1716000000-a1b2c3          myapp          running    8412     4m32s        2025-01-01T12:00:00Z
```

---

### Inspect a single environment in detail

```bash
make inspect ENV=env-1716000000-a1b2c3
```

Shows: container status, last health check result, TTL remaining, Nginx config presence, log PID.

---

## 7. Monitor Health

The health monitor (`sandbox-monitor` container) polls every active environment's `/health` endpoint every **30 seconds** and writes results to `logs/<ENV_ID>/health.log`.

---

### 7.1 Wait for the first poll

```bash
sleep 35
ls logs/env-1716000000-a1b2c3/health.log
```

---

### 7.2 View the last 10 health checks via API

```bash
curl -s http://localhost:7000/envs/env-1716000000-a1b2c3/health | python3 -m json.tool
```

Each check includes:

```json
{
    "env_id": "env-1716000000-a1b2c3",
    "ts": "2025-01-01T12:00:30Z",
    "url": "http://localhost:8412/health",
    "http_status": 200,
    "latency_ms": 4,
    "status": "ok"
}
```

---

### 7.3 View all env health in the terminal dashboard

```bash
make health
```

---

### 7.4 Watch the health log live

Open a second terminal and run:

```bash
tail -f logs/env-1716000000-a1b2c3/health.log
```

Keep this running — it lets you observe failures in real time during outage simulation.

---

## 8. Simulate an Outage

> Before running any simulation, open a second terminal with `tail -f logs/<ENV_ID>/health.log` so you can watch the health monitor catch the failure.

---

### Mode: `crash` — hard kill

```bash
make simulate ENV=env-1716000000-a1b2c3 MODE=crash
```

`docker kill` is sent to the container. It stops immediately. Health monitor detects this as `unreachable` within 30 seconds.

---

### Mode: `pause` — freeze the process

```bash
make simulate ENV=env-1716000000-a1b2c3 MODE=pause
```

`docker pause` suspends the container's processes. The container still exists but all HTTP requests time out. Useful for simulating a hung process.

---

### Mode: `network` — isolate from the network

```bash
make simulate ENV=env-1716000000-a1b2c3 MODE=network
```

Disconnects the container from both its dedicated network and `sandbox-nginx-net`. The process keeps running but is completely unreachable. Nginx begins returning `502 Bad Gateway`.

---

### Mode: `stress` — CPU spike

```bash
make simulate ENV=env-1716000000-a1b2c3 MODE=stress
```

Runs a CPU burner inside the container for 60 seconds (2 threads). Self-resolving — no recover needed.

---

### Via the REST API

```bash
curl -s -X POST http://localhost:7000/envs/env-1716000000-a1b2c3/outage \
  -H 'Content-Type: application/json' \
  -d '{"mode":"crash"}'
```

---

### Safety guard

`simulate_outage.sh` refuses to run against infrastructure containers. If you accidentally target `nginx`, `daemon`, `api`, or `monitor`, it exits immediately:

```
🚫 SAFETY: Refusing to simulate outage on protected container: sandbox-nginx
```

---

## 9. Observe Degradation

After **3 consecutive health check failures** (~90 seconds), the health monitor marks the environment as `degraded` and prints a warning.

Check current status:

```bash
make health
# status=degraded

curl -s http://localhost:7000/envs/env-1716000000-a1b2c3 | python3 -m json.tool
# "status": "degraded"
```

Watch the state file update live:

```bash
watch -n5 'cat envs/env-1716000000-a1b2c3.json | python3 -m json.tool'
```

---

## 10. View Logs

### Tail the application log live

```bash
make logs ENV=env-1716000000-a1b2c3
```

This follows `logs/<ENV_ID>/app.log`. The log shipper (`docker logs -f`) has been piping to this file since the environment was created.

---

### Fetch last 100 lines via API

```bash
curl -s http://localhost:7000/envs/env-1716000000-a1b2c3/logs | python3 -m json.tool
```

---

### Check the cleanup daemon log

```bash
tail -f logs/cleanup.log
```

Every 60 seconds you'll see a timestamped TTL check entry for each active environment.

---

### Export logs as a tarball

```bash
bash scripts/export_logs.sh env-1716000000-a1b2c3
# ✅ Logs exported: ./env-1716000000-a1b2c3-logs-20250101-120000.tar.gz (4.0K)
```

---

## 11. Recover

### Run recover mode

```bash
make simulate ENV=env-1716000000-a1b2c3 MODE=recover
```

The script inspects the container's current state and applies the right fix:

| Current state | Action taken |
|---|---|
| `paused` | `docker unpause` |
| `exited` / `dead` | `docker start` |
| `running` (network lost) | `docker network connect` (both networks) |

Status is then atomically reset to `running` in the state file.

---

### Or via the API

```bash
curl -s -X POST http://localhost:7000/envs/env-1716000000-a1b2c3/outage \
  -H 'Content-Type: application/json' \
  -d '{"mode":"recover"}'
```

---

### Confirm health is restored

Within 30 seconds the health monitor picks up a successful `/health` response and resets the status from `degraded` back to `running`:

```bash
make health
# status=running, last_check=ok 3ms
```

---

## 12. Optional — Netdata Dashboard

Netdata gives you a live visual dashboard of every container's CPU, memory, network I/O, and disk — with zero configuration. It auto-discovers sandbox containers the moment they start.

### Start

```bash
make monitoring-up
```

Expected output:

```
✅ Netdata dashboard: http://localhost:19999
   Auto-discovering all sandbox containers — no setup needed.
```

Open `http://localhost:19999` in your browser. Navigate to **Containers** in the left sidebar to see per-env metrics grouped by container name.

---

### What you get out of the box

- **Per-container CPU** — spot the spike from `MODE=stress` instantly
- **Per-container memory** — watch memory grow if an env is leaking
- **Network I/O** — see traffic drop to zero after `MODE=network`
- **Host-level system metrics** — load average, disk, RAM
- **Built-in alerts** — Netdata fires its own warnings for memory pressure and high CPU without any configuration

---

### Check Netdata status

```bash
make monitoring-status
```

---

### Stop

```bash
make monitoring-down
```

Netdata data persists in Docker volumes (`netdata-lib`, `netdata-cache`) and is available again when you restart it.

---

## 13. Destroy an Environment

### Manual destroy via Make

```bash
make destroy ENV=env-1716000000-a1b2c3
```

---

### Via the REST API

```bash
curl -s -X DELETE http://localhost:7000/envs/env-1716000000-a1b2c3
```

---

### What `destroy_env.sh` does under the hood

1. Reads `log_pid` from the state file and kills the log shipper process (prevents zombie `docker logs` processes)
2. Stops and removes all containers labeled `sandbox.env=<ENV_ID>`
3. Removes the Docker network (`sandbox-net-<ENV_ID>`)
4. Deletes `nginx/conf.d/<ENV_ID>.conf` and reloads Nginx
5. Copies everything in `logs/<ENV_ID>/` to `logs/archived/<ENV_ID>/`
6. Removes `logs/<ENV_ID>/`
7. Deletes `envs/<ENV_ID>.json`

---

### Verify destroy was clean

```bash
# State file gone
ls envs/

# Logs archived
ls logs/archived/env-1716000000-a1b2c3/

# Container gone
docker ps -a --filter 'label=sandbox.env=env-1716000000-a1b2c3'

# Network gone
docker network ls --filter 'label=sandbox.env=env-1716000000-a1b2c3'

# Nginx config gone
ls nginx/conf.d/
```

---

## 14. Watch Auto-Destroy via TTL

Create an environment with a very short TTL to watch the cleanup daemon work:

```bash
bash platform/create_env.sh demo-ttl 90
```

In a separate terminal, watch the daemon log:

```bash
tail -f logs/cleanup.log
```

Every 60 seconds the daemon checks all state files. When `now > created_at_epoch + ttl`, it calls `destroy_env.sh` automatically. You'll see:

```
2025-01-01T12:02:00Z ⏰ TTL expired for env-1716000090-x9y8z7 (demo-ttl) — destroying...
2025-01-01T12:02:03Z ✅ Destroyed env-1716000090-x9y8z7 successfully
```

---

## 15. Stop the Platform

```bash
make down
```

This destroys all remaining active environments first, then stops all four infrastructure containers.

---

## 16. Full Wipe

Wipes all state files, logs, archives, and per-env Nginx configs. **Cannot be undone.**

```bash
make clean
```

For a nuclear reset when `make clean` isn't enough (e.g. containers stuck in a bad state):

```bash
bash scripts/reset_platform.sh
```

This prompts for confirmation, then force-removes all sandbox containers, networks, state files, and logs.

---

## 17. Running the Test Suite

All tests require the platform to be running (`make up`) and `sandbox-demo-app:latest` to be built (`make build-app`).

---

### API integration tests (12 assertions)

```bash
make test
```

Tests: API health, create, list, get, TTL remaining, logs endpoint, health endpoint, invalid outage mode rejection, 404 for unknown env, destroy, 404 after destroy.

---

### Full lifecycle test

```bash
make test-lifecycle
```

Runs the complete cycle: create → verify state file → verify container → verify Nginx config → test `/health` → crash → recover → verify recovery → destroy → verify all cleanup.

---

### Outage simulation tests

```bash
bash tests/test_outage.sh
```

Tests all four modes (`crash`, `pause`, `network`, `recover`) with before/after state assertions, plus the safety guard.

---

### Cleanup daemon TTL test

```bash
bash tests/test_cleanup_daemon.sh
```

Creates an environment with a 10-second TTL and waits up to 130 seconds for the daemon to auto-destroy it. Also verifies the cleanup log entry and archive directory.

---

## 18. Troubleshooting

---

### API returns `connection refused`

The API container didn't start or crashed on startup.

```bash
docker logs sandbox-api --tail 50
docker compose ps
```

If it exited, rebuild and restart:

```bash
docker compose up -d --build api
```

---

### `sandbox-demo-app:latest` not found on create

You need to build the demo app image first:

```bash
make build-app
```

---

### Nginx returns `502 Bad Gateway` for an environment

The app container is not connected to `sandbox-nginx-net`. Check:

```bash
docker inspect sandbox-app-env-YOUR-ID \
  --format '{{json .NetworkSettings.Networks}}' | python3 -m json.tool
```

If `sandbox-nginx-net` is missing, reconnect it:

```bash
docker network connect sandbox-nginx-net sandbox-app-env-YOUR-ID
```

---

### Nginx config test fails after a create

```bash
docker exec sandbox-nginx nginx -t
```

This shows exactly which config line is invalid. Usually caused by a naming collision or a stale config file from a previous failed create.

---

### Port collision on environment create

The script retries random ports in the `8100–9000` range, but if the range is saturated it will loop. Check what's bound:

```bash
ss -tlnp | grep -E ':8[1-9][0-9]{2}'
```

Widen the range in `.env` if needed (`ENV_PORT_MIN`, `ENV_PORT_MAX`).

---

### Health monitor not updating status

Check if the monitor container is running:

```bash
docker logs sandbox-monitor --tail 30
```

If it crashed, restart it:

```bash
docker compose up -d monitor
```

---

### Cleanup daemon not destroying expired envs

```bash
docker logs sandbox-daemon --tail 30
```

The daemon requires `bash` and `python3` — it installs them at startup in the `docker:24-cli` image. If the container is still in the install phase wait 10 seconds and check again.

---

### Emergency force-wipe (if `make clean` itself fails)

```bash
# Force-remove all sandbox app containers
docker ps -aq --filter 'label=sandbox.env' | xargs docker rm -f

# Force-remove all sandbox networks
docker network ls -q --filter 'label=sandbox.env' | xargs docker network rm

# Wipe state and nginx configs
rm -f envs/*.json nginx/conf.d/env-*.conf
```

Then restart cleanly:

```bash
make up
```
