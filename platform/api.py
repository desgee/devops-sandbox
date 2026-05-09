#!/usr/bin/env python3
"""
api.py — Control API for devops-sandbox platform
Wraps platform scripts with a REST interface.
"""

import os
import json
import glob
import subprocess
import time
from pathlib import Path
from flask import Flask, jsonify, request, abort

app = Flask(__name__)

ROOT_DIR = Path(__file__).parent.parent.resolve()
ENVS_DIR = ROOT_DIR / "envs"
LOGS_DIR = ROOT_DIR / "logs"
PLATFORM_DIR = ROOT_DIR / "platform"


# ── Helpers ───────────────────────────────────────────────────────────────────

def load_state(env_id: str) -> dict | None:
    state_file = ENVS_DIR / f"{env_id}.json"
    if not state_file.exists():
        return None
    with open(state_file) as f:
        return json.load(f)


def save_state(env_id: str, data: dict):
    state_file = ENVS_DIR / f"{env_id}.json"
    tmp = state_file.with_suffix(".tmp")
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
    tmp.rename(state_file)


def ttl_remaining(state: dict) -> int:
    expires = state["created_at_epoch"] + state["ttl"]
    return max(0, int(expires - time.time()))


def run_script(script: str, *args) -> tuple[int, str, str]:
    script_path = PLATFORM_DIR / script
    result = subprocess.run(
        ["bash", str(script_path), *args],
        capture_output=True, text=True
    )
    return result.returncode, result.stdout, result.stderr


# ── Routes ────────────────────────────────────────────────────────────────────

@app.route("/health", methods=["GET"])
def api_health():
    """API self-health check."""
    return jsonify({"status": "ok", "service": "devops-sandbox-api"})


@app.route("/envs", methods=["POST"])
def create_env():
    """Create a new sandbox environment."""
    body = request.get_json(silent=True) or {}
    name = body.get("name", "")
    ttl = str(body.get("ttl", 1800))

    if not name:
        return jsonify({"error": "name is required"}), 400

    rc, stdout, stderr = run_script("create_env.sh", name, ttl)
    if rc != 0:
        return jsonify({"error": "Failed to create env", "details": stderr}), 500

    # Find the newly created env ID from stdout
    env_id = None
    for line in stdout.splitlines():
        if line.strip().startswith("ID:"):
            env_id = line.split("ID:")[-1].strip()
            break

    # Fallback: scan envs/ for recently created
    if not env_id:
        states = sorted(ENVS_DIR.glob("*.json"), key=lambda p: p.stat().st_mtime, reverse=True)
        if states:
            env_id = states[0].stem

    state = load_state(env_id) if env_id else None
    if state:
        state["ttl_remaining"] = ttl_remaining(state)
        return jsonify(state), 201

    return jsonify({"message": "Created", "output": stdout}), 201


@app.route("/envs", methods=["GET"])
def list_envs():
    """List all active environments with TTL remaining."""
    envs = []
    for state_file in ENVS_DIR.glob("*.json"):
        try:
            with open(state_file) as f:
                state = json.load(f)
            state["ttl_remaining"] = ttl_remaining(state)
            envs.append(state)
        except Exception:
            continue
    envs.sort(key=lambda e: e.get("created_at_epoch", 0), reverse=True)
    return jsonify(envs)


@app.route("/envs/<env_id>", methods=["GET"])
def get_env(env_id: str):
    """Get details for a specific environment."""
    state = load_state(env_id)
    if not state:
        return jsonify({"error": "not found"}), 404
    state["ttl_remaining"] = ttl_remaining(state)
    return jsonify(state)


@app.route("/envs/<env_id>", methods=["DELETE"])
def destroy_env(env_id: str):
    """Destroy a sandbox environment."""
    if not load_state(env_id):
        return jsonify({"error": "not found"}), 404

    rc, stdout, stderr = run_script("destroy_env.sh", env_id)
    if rc != 0:
        return jsonify({"error": "Destroy failed", "details": stderr}), 500

    return jsonify({"message": f"Environment {env_id} destroyed"}), 200


@app.route("/envs/<env_id>/logs", methods=["GET"])
def get_logs(env_id: str):
    """Return last 100 lines of app.log for an environment."""
    # Check active logs first, then archived
    log_path = LOGS_DIR / env_id / "app.log"
    if not log_path.exists():
        log_path = LOGS_DIR / "archived" / env_id / "app.log"

    if not log_path.exists():
        return jsonify({"error": "No logs found", "env_id": env_id}), 404

    result = subprocess.run(
        ["tail", "-n", "100", str(log_path)],
        capture_output=True, text=True
    )
    lines = result.stdout.splitlines()
    return jsonify({"env_id": env_id, "lines": lines, "count": len(lines)})


@app.route("/envs/<env_id>/health", methods=["GET"])
def get_health(env_id: str):
    """Return last 10 health check results."""
    health_path = LOGS_DIR / env_id / "health.log"
    if not health_path.exists():
        health_path = LOGS_DIR / "archived" / env_id / "health.log"

    if not health_path.exists():
        return jsonify({"env_id": env_id, "checks": [], "message": "No health data yet"})

    result = subprocess.run(
        ["tail", "-n", "10", str(health_path)],
        capture_output=True, text=True
    )
    checks = []
    for line in result.stdout.splitlines():
        try:
            checks.append(json.loads(line))
        except json.JSONDecodeError:
            checks.append({"raw": line})

    state = load_state(env_id)
    return jsonify({
        "env_id": env_id,
        "status": state.get("status", "unknown") if state else "unknown",
        "checks": checks
    })


@app.route("/envs/<env_id>/outage", methods=["POST"])
def simulate_outage(env_id: str):
    """Trigger an outage simulation."""
    if not load_state(env_id):
        return jsonify({"error": "not found"}), 404

    body = request.get_json(silent=True) or {}
    mode = body.get("mode", "")
    valid_modes = {"crash", "pause", "network", "recover", "stress"}

    if mode not in valid_modes:
        return jsonify({"error": f"Invalid mode. Must be one of: {', '.join(valid_modes)}"}), 400

    rc, stdout, stderr = run_script("simulate_outage.sh", "--env", env_id, "--mode", mode)
    if rc != 0:
        return jsonify({"error": "Simulation failed", "details": stderr}), 500

    return jsonify({"env_id": env_id, "mode": mode, "message": f"Outage simulation '{mode}' applied"})


# ── Main ──────────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    ENVS_DIR.mkdir(exist_ok=True)
    LOGS_DIR.mkdir(exist_ok=True)

    host = os.environ.get("API_HOST", "0.0.0.0")
    port = int(os.environ.get("API_PORT", "7000"))

    print(f"🚀 devops-sandbox API starting on {host}:{port}")
    app.run(host=host, port=port, debug=False)
