#!/usr/bin/env bash
# scripts/build_demo_app.sh — Build the sandbox-demo-app Docker image
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TAG="${1:-sandbox-demo-app:latest}"

echo "🔨 Building demo app image: $TAG"
docker build -f "$ROOT_DIR/apps/demo/Dockerfile" -t "$TAG" "$ROOT_DIR/apps/demo/"
echo "✅ Built: $TAG"
