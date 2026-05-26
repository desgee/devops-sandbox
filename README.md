# devops-sandbox

A self-service platform for spinning up isolated temporary environments, deploying apps, simulating outages, monitoring health, and auto-destroying everything. Think miniature internal Heroku.

Every environment is short-lived by design.

---

## Architecture

```
                            ┌─────────────────────────────────────────────────┐
                            │                  Linux VM / Host                  │
                            │                                                   │
  User / CI                 │  ┌─────────────────────────────────────────────┐ │
    │                       │  │           Docker Engine                     │ │
    │  make / curl          │  │                                             │ │
    ▼                       │  │  ┌──────────┐   ┌──────────┐  ┌─────────┐ │ │
┌───────────┐               │  │  │          │   │          │  │         │ │ │
│ Makefile  │──────────────▶│  │  │  nginx   │   │  API     │  │ daemon  │ │ │
│ (make up) │               │  │  │ :8080    │   │ :7000    │  │(cleanup)│ │ │
└───────────┘               │  │  │          │   │          │  │         │ │ │
                            │  │  └────┬─────┘   └────┬─────┘  └────┬────┘ │ │
┌───────────┐               │  │       │               │              │      │ │
│  REST API │──────────────▶│  │       │    sandbox-nginx-net         │      │ │
│ /envs     │               │  │       │─────────────────────         │      │ │
└───────────┘               │  │                                      │      │ │
                            │  │  ┌─────────────────────────────────┐ │      │ │
                            │  │  │      Sandbox Environments        │ │      │ │
                            │  │  │                                  │ │      │ │
                            │  │  │  ┌───────────┐  ┌───────────┐  │ │      │ │
                            │  │  │  │env-abc123 │  │env-def456 │  │◀┘      │ │
                            │  │  │  │ app:5000  │  │ app:5000  │  │        │ │
                            │  │  │  │ net: own  │  │ net: own  │  │        │ │
                            │  │  │  └───────────┘  └───────────┘  │        │ │
                            │  │  └─────────────────────────────────┘        │ │
                            │  │                                              │ │
                            │  │  ┌──────────┐  logs/ ──────────────────────▶│ │
                            │  │  │ monitor  │  envs/ (state files)          │ │
                            │  │  │(health)  │  nginx/conf.d/ (per-env)      │ │
                            │  │  └──────────┘                               │ │
                            │  └─────────────────────────────────────────────┘ │
                            └─────────────────────────────────────────────────┘

  Request flow:
  Browser → Nginx (:8080) → upstream sandbox-app-<env_id>:5000
  Nginx routes by Host header: env-abc123.sandbox.local → env-abc123 container

  Data flow:
  create_env.sh → Docker network + container + Nginx conf + state file
  cleanup_daemon.sh → reads envs/*.json → calls destroy_env.sh when TTL expired
  health_monitor.py → polls localhost:<port>/health every 30s → writes health.log
```

---

## Prerequisites

- Docker ≥ 24.x and Docker Compose ≥ 2.20
- Python 3.11+ (on the host, for the health monitor)
- Bash 4+, GNU Make
- A Linux VM (tested on Ubuntu 22.04/24.04)

---

## Quick Start

Zero to first running environment in 5 commands:

```bash
git clone https://github.com/YOUR_USERNAME/devops-sandbox.git
cd devops-sandbox
cp .env.example .env          # review defaults; edit ports if needed
make up                       # starts Nginx, API, cleanup daemon, monitor
make create                   # prompts for name + TTL, creates env
```

After `make create` you'll see:

```
╔══════════════════════════════════════════╗
║  Environment Ready!                      ║
║  ID:   env-1716000000-a1b2c3             ║
║  URL:  http://localhost:8412             ║
║  TTL:  1800s (expires in 30 min)         ║
╚══════════════════════════════════════════╝
```

---

## Full Demo Walkthrough

### 1 — Create an environment

```bash
make create
# name: myapp
# ttl: 300   (5 minutes for demo)
```

Or via the API:
```bash
curl -s -X POST http://localhost:7000/envs \
  -H 'Content-Type: application/json' \
  -d '{"name":"myapp","ttl":300}' | python3 -m json.tool
```

### 2 — Confirm it's running

```bash
make status
# or
curl -s http://localhost:7000/envs | python3 -m json.tool
```

Hit the app directly (port shown at creation time):
```bash
curl http://localhost:<PORT>/health
# {"status": "ok", "env_id": "env-...", ...}
```

### 3 — Check health

```bash
make health

# or via API (last 10 results):
curl -s http://localhost:7000/envs/<ENV_ID>/health | python3 -m json.tool
```

### 4 — Simulate an outage

**Crash the container:**
```bash
make simulate ENV=env-1716000000-a1b2c3 MODE=crash
```

**Pause it (freeze, not kill):**
```bash
make simulate ENV=env-1716000000-a1b2c3 MODE=pause
```

**Network isolation:**
```bash
make simulate ENV=env-1716000000-a1b2c3 MODE=network
```

Or via the API:
```bash
curl -s -X POST http://localhost:7000/envs/<ENV_ID>/outage \
  -H 'Content-Type: application/json' \
  -d '{"mode":"crash"}'
```

### 5 — Observe degradation

Within 90 seconds the health monitor will detect failures. After 3 consecutive failures, status becomes `degraded`:

```bash
make health
# status=degraded

curl -s http://localhost:7000/envs/<ENV_ID>/health
```

Watch the health log live:
```bash
tail -f logs/<ENV_ID>/health.log
```

### 6 — Recover

```bash
make simulate ENV=env-1716000000-a1b2c3 MODE=recover
# or
curl -s -X POST http://localhost:7000/envs/<ENV_ID>/outage \
  -H 'Content-Type: application/json' \
  -d '{"mode":"recover"}'
```

Health monitor detects recovery and resets status to `running`.

### 7 — View logs

```bash
make logs ENV=env-1716000000-a1b2c3
# tails logs/<ENV_ID>/app.log live

# or via API (last 100 lines):
curl -s http://localhost:7000/envs/<ENV_ID>/logs
```

### 8 — Manual destroy

```bash
make destroy ENV=env-1716000000-a1b2c3
```

### 9 — Auto-destroy (TTL)

If you set a short TTL (e.g. 60s), the cleanup daemon destroys it automatically. Watch it happen:

```bash
tail -f logs/cleanup.log
```

---

## API Reference

| Method   | Endpoint                  | Description                          |
|----------|---------------------------|--------------------------------------|
| `POST`   | `/envs`                   | Create env — body: `{name, ttl}`     |
| `GET`    | `/envs`                   | List all active envs + TTL remaining |
| `GET`    | `/envs/:id`               | Get single env details               |
| `DELETE` | `/envs/:id`               | Destroy env                          |
| `GET`    | `/envs/:id/logs`          | Last 100 lines of app.log            |
| `GET`    | `/envs/:id/health`        | Last 10 health check results         |
| `POST`   | `/envs/:id/outage`        | Trigger simulation — body: `{mode}`  |

---

## Make Targets

| Target                          | Description                                 |
|---------------------------------|---------------------------------------------|
| `make up`                       | Start Nginx, daemon, API, monitor           |
| `make down`                     | Stop everything, destroy all envs           |
| `make create`                   | Interactive: create new env                 |
| `make destroy ENV=<id>`         | Destroy specific env                        |
| `make logs ENV=<id>`            | Tail env app.log (live)                     |
| `make health`                   | Show all env health statuses                |
| `make simulate ENV=<id> MODE=<mode>` | Run outage simulation                  |
| `make status`                   | List envs via API (JSON)                    |
| `make clean`                    | Wipe all state, logs, archives              |

### Outage modes

| Mode      | Effect                                           | Recovery          |
|-----------|--------------------------------------------------|-------------------|
| `crash`   | `docker kill` — hard stop                        | `MODE=recover`    |
| `pause`   | `docker pause` — freeze process                  | `MODE=recover`    |
| `network` | Disconnect from Docker networks                   | `MODE=recover`    |
| `recover` | Unpause / restart / reconnect as needed          | —                 |
| `stress`  | CPU spike via stress-ng or Python burner (60s)   | Self-resolving    |

---

## Nginx Routing

Nginx is the front door for all environments. Each `create_env.sh` call writes a config to `nginx/conf.d/<ENV_ID>.conf` and runs `nginx -s reload`. On destroy, the file is removed and Nginx is reloaded again.

**Routing strategy:** Host-header based. Each env gets a virtual server name `<ENV_ID>.sandbox.local`. For local testing, hit by port directly (each env gets a random host port). For proper hostname routing, add entries to `/etc/hosts` or use a wildcard DNS entry.

**Network:** Nginx runs in `sandbox-nginx-net`. App containers are also joined to this network at creation time, so Nginx can upstream to `sandbox-app-<ENV_ID>:5000` by container name.

---

## Log Shipping

**Approach A (implemented):** At container creation, `docker logs -f <container> >> logs/<ENV_ID>/app.log &` is run and the PID saved to `logs/<ENV_ID>/log_shipper.pid`. On destroy, this PID is killed before container removal to prevent zombie processes.

Logs are archived to `logs/archived/<ENV_ID>/` on destroy and remain queryable.

---

## Monitoring (optional — Netdata)

Netdata is an optional add-on that gives you a live dashboard of every container's CPU, memory, network I/O, and disk — with zero configuration. It auto-discovers all sandbox containers via the Docker socket the moment they start.

**Start:**
```bash
make monitoring-up
# Dashboard: http://localhost:19999
```

**Stop:**
```bash
make monitoring-down
```

What you get instantly, with no setup:
- Per-container CPU and memory graphs — including each `sandbox-app-<id>` as it's created
- Host-level system metrics (load, disk, network)
- Built-in alerts for memory pressure and high CPU
- Live log of containers appearing and disappearing as you create/destroy envs

Metrics are retained in a Docker volume (`netdata-lib`, `netdata-cache`) so they survive restarts. Configuration is in `monitor/netdata/netdata.conf` — the defaults are fine for local use.

---

## File Structure

```
devops-sandbox/
├── platform/
│   ├── create_env.sh         # Spin up environment
│   ├── destroy_env.sh        # Tear down environment
│   ├── cleanup_daemon.sh     # TTL auto-expire loop
│   ├── simulate_outage.sh    # Chaos injection
│   ├── api.py                # Flask REST API
│   └── lib/
│       └── common.sh         # Shared functions (state, docker, nginx helpers)
├── apps/
│   └── demo/
│       ├── app.py            # Demo HTTP server (/  /health  /info)
│       └── Dockerfile
├── nginx/
│   ├── nginx.conf            # Main config (includes conf.d/)
│   └── conf.d/               # Auto-generated per-env configs (gitignored)
├── monitor/
│   ├── health_monitor.py     # 30s health poller → health.log
│   └── netdata/
│       └── netdata.conf      # Netdata config (update_every, retention, plugins)
├── scripts/
│   ├── inspect.sh            # Pretty-print env runtime state
│   ├── list_envs.sh          # Formatted table of all active envs
│   ├── build_demo_app.sh     # Build sandbox-demo-app:latest
│   ├── export_logs.sh        # Tarball logs for any env
│   ├── prune_archives.sh     # Remove archived logs older than N days
│   └── reset_platform.sh     # Nuclear wipe with confirmation
├── tests/
│   ├── test_api.sh           # 12 API integration assertions
│   ├── test_lifecycle.sh     # Full create→crash→recover→destroy cycle
│   ├── test_outage.sh        # All outage modes tested end-to-end
│   └── test_cleanup_daemon.sh # TTL auto-expiry test (~2 min)
├── logs/                     # gitignored
│   ├── cleanup.log
│   ├── <env_id>/
│   │   ├── app.log
│   │   └── health.log
│   └── archived/
├── envs/                     # gitignored — runtime state JSONs
├── .env.example
├── .gitignore
├── docker-compose.yml            # Core platform (nginx, api, daemon, monitor)
├── docker-compose.monitoring.yml # Optional Netdata (make monitoring-up)
├── Dockerfile.api
├── Makefile
├── requirements.txt
├── CONTRIBUTING.md
└── README.md
```

---

## Known Limitations

- **Single VM only.** No distributed scheduling — everything runs on one host. This is by design.
- **Port allocation.** Env ports are random (8100–9000). High concurrency could exhaust this range. For >900 envs, widen the range.
- **No auth on the API.** The API is unauthenticated. Do not expose port 7000 publicly without adding auth middleware.
- **Demo app is ephemeral.** The bundled Python HTTP server is not production-grade — it's a placeholder to satisfy `/health`. Swap it for your own image via `create_env.sh`.
- **Nginx config reload is not atomic.** Between `rm` and `nginx -s reload`, Nginx may briefly serve a 502 for that env. For production, use `nginx -t` validation before reloading.
- **Log shipper depends on `docker logs`.** On high-throughput containers this can lag. For production use Approach B (Loki/Fluentd via Docker socket).
- **Cleanup daemon requires bash + python3 in the daemon container.** The `docker:24-cli` image installs these at startup, which adds ~5s cold start.
- **No TLS.** All traffic is plain HTTP. Add Certbot + nginx SSL termination for production use.
