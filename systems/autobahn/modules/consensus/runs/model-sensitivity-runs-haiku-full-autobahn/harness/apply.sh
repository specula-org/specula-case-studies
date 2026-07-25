#!/bin/bash
# Apply instrumentation patches to Autobahn consensus artifact

set -e

ARTIFACT_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/autobahn/artifact/autobahn"
HARNESS_DIR="/home/ubuntu/Specula/experiments/model-sensitivity/runs/haiku/full/autobahn/harness"

# Copy trace module to primary crate
cp "$HARNESS_DIR/src/tla_trace.rs" "$ARTIFACT_DIR/primary/src/"

# Update Cargo.toml to include dependencies
cd "$ARTIFACT_DIR/primary"

# Check if dependencies are already in Cargo.toml
if ! grep -q "serde_json" Cargo.toml; then
    # Add dependencies after tokio
    sed -i '/tokio = /a serde_json = "1.0"\nlazy_static = "1.4"' Cargo.toml
fi

# Update lib.rs to include the trace module
if ! grep -q "pub mod tla_trace" src/lib.rs; then
    echo "pub mod tla_trace;" >> src/lib.rs
fi

echo "✓ Instrumentation applied to primary crate"
