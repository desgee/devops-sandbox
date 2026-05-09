# Contributing to devops-sandbox

## Development setup

```bash
git clone https://github.com/YOUR_USERNAME/devops-sandbox.git
cd devops-sandbox
cp .env.example .env
chmod +x platform/*.sh scripts/*.sh tests/*.sh
make build-app   # build sandbox-demo-app:latest
make up          # start the platform
```

## Running tests

```bash
make test              # API integration tests (requires make up)
make test-lifecycle    # Full create→crash→recover→destroy cycle
bash tests/test_outage.sh         # All outage modes
bash tests/test_cleanup_daemon.sh # TTL auto-expiry (takes ~2 min)
```

## Project layout

```
platform/           Scripts wrapping Docker + Nginx + state
  lib/common.sh     Shared helper functions (sourced, not executed)
apps/demo/          Demo app placed inside sandbox environments
monitor/            Health poller + Netdata config
  netdata/          netdata.conf — update_every, retention, plugins
nginx/              Nginx main config + runtime per-env configs
scripts/            Dev helper scripts (inspect, export-logs, reset)
tests/              Shell-based integration and smoke tests
```

## Adding a new outage mode

1. Add a `case` branch in `platform/simulate_outage.sh`
2. Document it in `README.md` (outage modes table)
3. Add a test case in `tests/test_outage.sh`

## Adding a new API endpoint

1. Add the route in `platform/api.py`
2. Add it to the API reference table in `README.md`
3. Add an assertion in `tests/test_api.sh`

## Code style

- Bash: 2-space indent, `set -euo pipefail` at top of every script, `shellcheck`-clean
- Python: standard library only in `api.py`, PEP 8, type hints on function signatures
- Commit messages: `type(scope): description` (e.g. `fix(destroy): kill log shipper before container stop`)
