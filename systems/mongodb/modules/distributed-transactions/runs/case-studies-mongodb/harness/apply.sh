#!/usr/bin/env bash
# Apply instrumentation: start the MongoDB sharded cluster.
# For MongoDB, "instrumentation" means running real mongod/mongos processes
# with verbose transaction logging (LOGV2 verbosity 4 on TXN component).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Stopping any existing cluster..."
docker compose down -v 2>/dev/null || true

echo "Starting MongoDB sharded cluster..."
docker compose up -d

echo "Initializing cluster (replica sets, sharding, seed data)..."
bash init_cluster.sh

echo "Cluster is ready. mongos on localhost:27017"
