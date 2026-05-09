#!/usr/bin/env python3
"""
health_monitor.py — Poll each active env's /health endpoint every 30s.
Tracks consecutive failures and marks env as "degraded" after 3.
"""

import json
import os
import sys
import time
import glob
import urllib.request
import urllib.error
from pathlib import Path
from datetime import datetime, timezone

ROOT_DIR = Path(__file__).parent.parent.resolve()
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"

POLL_INTERVAL = 30
DEGRADED_THRESHOLD = 3

# Track consecutive failures per env
failure_counts: dict[str, int] = {}


def ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_state(env_id: str) -> dict | None:
    path = ENVS_DIR / f"{env_id}.json"
    if not path.exists():
        return None
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def save_status(env_id: str, status: str):
    """Atomically update status in state file."""
    path = ENVS_DIR / f"{env_id}.json"
    if not path.exists():
        return
    try:
        with open(path) as f:
            data = json.load(f)
        data["status"] = status
        tmp = path.with_suffix(".tmp")
        with open(tmp, "w") as f:
            json.dump(data, f, indent=2)
        tmp.rename(path)
    except Exception as e:
        print(f"[{ts()}] ⚠️  Could not update state for {env_id}: {e}")


def poll_env(env_id: str, state: dict) -> dict:
    """Poll /health for one environment. Returns a result dict."""
    port = state.get("port")
    if not port:
        return {"env_id": env_id, "ts": ts(), "status": "error", "latency_ms": 0, "reason": "no port"}

    url = f"http://localhost:{port}/health"
    start = time.monotonic()
    result = {
        "env_id": env_id,
        "ts": ts(),
        "url": url,
    }

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "sandbox-health-monitor/1.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            latency_ms = int((time.monotonic() - start) * 1000)
            result.update({
                "http_status": resp.status,
                "latency_ms": latency_ms,
                "status": "ok" if resp.status == 200 else "error",
            })
    except urllib.error.HTTPError as e:
        latency_ms = int((time.monotonic() - start) * 1000)
        result.update({
            "http_status": e.code,
            "latency_ms": latency_ms,
            "status": "error",
            "reason": str(e),
        })
    except Exception as e:
        latency_ms = int((time.monotonic() - start) * 1000)
        result.update({
            "http_status": 0,
            "latency_ms": latency_ms,
            "status": "unreachable",
            "reason": str(e),
        })

    return result


def write_health_log(env_id: str, result: dict):
    log_dir = LOGS_DIR / env_id
    log_dir.mkdir(parents=True, exist_ok=True)
    with open(log_dir / "health.log", "a") as f:
        f.write(json.dumps(result) + "\n")


def monitor_loop():
    print(f"[{ts()}] 🟢 Health monitor started (interval={POLL_INTERVAL}s, threshold={DEGRADED_THRESHOLD})")

    while True:
        state_files = list(ENVS_DIR.glob("*.json"))

        if not state_files:
            print(f"[{ts()}]    No active environments to monitor")
        else:
            for state_file in state_files:
                env_id = state_file.stem
                state = load_state(env_id)
                if not state:
                    continue

                result = poll_env(env_id, state)
                write_health_log(env_id, result)

                name = state.get("name", env_id)
                current_status = state.get("status", "unknown")

                if result["status"] == "ok":
                    # Reset failure counter
                    if env_id in failure_counts:
                        del failure_counts[env_id]
                    if current_status == "degraded":
                        save_status(env_id, "running")
                        print(f"[{ts()}] ✅ {env_id} ({name}): recovered — {result['latency_ms']}ms")
                    else:
                        print(f"[{ts()}] ✅ {env_id} ({name}): ok — {result['latency_ms']}ms")
                else:
                    failure_counts[env_id] = failure_counts.get(env_id, 0) + 1
                    count = failure_counts[env_id]
                    print(f"[{ts()}] ⚠️  {env_id} ({name}): {result['status']} (failure {count}/{DEGRADED_THRESHOLD}) — {result.get('reason', '')}")

                    if count >= DEGRADED_THRESHOLD and current_status != "degraded":
                        save_status(env_id, "degraded")
                        print(f"[{ts()}] 🚨 DEGRADED: {env_id} ({name}) — {DEGRADED_THRESHOLD} consecutive failures!")

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    LOGS_DIR.mkdir(exist_ok=True)
    try:
        monitor_loop()
    except KeyboardInterrupt:
        print(f"\n[{ts()}] Health monitor stopped.")
