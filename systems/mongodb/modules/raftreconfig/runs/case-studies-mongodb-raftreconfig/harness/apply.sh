#!/usr/bin/env bash
# Apply instrumentation: start the MongoDB replica set cluster.
# For MongoDB, "instrumentation" means running mongod with verbose
# replication logging (LOGV2 verbosity 3 on REPL+ELECTION components).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Stopping any existing cluster..."
docker compose down -v 2>/dev/null || true

echo "Starting MongoDB 5-node replica set cluster..."
docker compose up -d

echo "Initializing replica set (3 of 5 nodes)..."
bash init_cluster.sh

echo "Cluster is ready. Connect via: docker exec mongo-rs0-1 mongosh"
