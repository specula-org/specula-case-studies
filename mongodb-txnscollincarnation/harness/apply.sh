#!/usr/bin/env bash
# Start the sharded cluster and initialize it.
# Idempotent: safe to re-run (will skip if already running).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

cd "$SCRIPT_DIR"

# Check if cluster is already running
if docker exec tci-mongos mongosh --quiet --eval "db.runCommand({ping:1})" >/dev/null 2>&1; then
    echo "Cluster already running."
    exit 0
fi

# Stop any previous containers
docker compose down -v 2>/dev/null || true

echo "Starting sharded cluster..."
docker compose up -d

echo "Initializing cluster..."
bash "$SCRIPT_DIR/init_cluster.sh"

echo "Cluster ready."
