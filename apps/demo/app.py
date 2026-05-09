#!/usr/bin/env python3
"""
demo app — sandbox-demo-app
A minimal HTTP server used as the placeholder app inside sandbox environments.
Exposes / and /health for the health monitor and Nginx routing.
"""

import http.server
import json
import os
import time
import threading
import socket

ENV_ID   = os.environ.get("ENV_ID",   "unknown")
ENV_NAME = os.environ.get("ENV_NAME", "unknown")
PORT     = int(os.environ.get("PORT", "5000"))
START_TS = time.time()

request_count = 0
request_lock  = threading.Lock()


class SandboxHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Structured log for docker logs capture
        print(json.dumps({
            "ts":     time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "method": self.command,
            "path":   self.path,
            "status": args[1] if len(args) > 1 else "-",
            "env_id": ENV_ID,
        }), flush=True)

    def send_json(self, code: int, body: dict):
        payload = json.dumps(body, indent=2).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Sandbox-Env", ENV_ID)
        self.end_headers()
        self.wfile.write(payload)

    def send_html(self, code: int, body: str):
        payload = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("X-Sandbox-Env", ENV_ID)
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        global request_count
        with request_lock:
            request_count += 1

        if self.path == "/health":
            self.send_json(200, {
                "status":    "ok",
                "env_id":    ENV_ID,
                "env_name":  ENV_NAME,
                "uptime_s":  round(time.time() - START_TS, 1),
                "requests":  request_count,
                "hostname":  socket.gethostname(),
                "ts":        time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            })

        elif self.path == "/info":
            self.send_json(200, {
                "env_id":   ENV_ID,
                "env_name": ENV_NAME,
                "port":     PORT,
                "hostname": socket.gethostname(),
                "python":   "3.11",
                "started":  time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(START_TS)),
            })

        else:
            uptime = int(time.time() - START_TS)
            self.send_html(200, f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Sandbox: {ENV_NAME}</title>
  <style>
    body {{ font-family: monospace; background: #0d1117; color: #e6edf3; padding: 3rem; }}
    h1   {{ color: #58a6ff; margin-bottom: 0.5rem; }}
    .kv  {{ display: grid; grid-template-columns: 140px 1fr; gap: 4px 16px; margin: 1.5rem 0; }}
    .k   {{ color: #8b949e; }}
    .v   {{ color: #e6edf3; }}
    a    {{ color: #58a6ff; }}
    .badge {{ display:inline-block; background:#238636; color:#fff; border-radius:4px;
              padding:2px 8px; font-size:12px; }}
  </style>
</head>
<body>
  <h1>devops-sandbox</h1>
  <span class="badge">running</span>
  <div class="kv">
    <span class="k">env_id</span>   <span class="v">{ENV_ID}</span>
    <span class="k">env_name</span> <span class="v">{ENV_NAME}</span>
    <span class="k">hostname</span> <span class="v">{socket.gethostname()}</span>
    <span class="k">uptime</span>   <span class="v">{uptime}s</span>
    <span class="k">requests</span> <span class="v">{request_count}</span>
  </div>
  <p><a href="/health">/health</a> &nbsp; <a href="/info">/info</a></p>
</body>
</html>""")


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("0.0.0.0", PORT), SandboxHandler)
    print(json.dumps({
        "ts":       time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "event":    "start",
        "env_id":   ENV_ID,
        "env_name": ENV_NAME,
        "port":     PORT,
    }), flush=True)
    server.serve_forever()
