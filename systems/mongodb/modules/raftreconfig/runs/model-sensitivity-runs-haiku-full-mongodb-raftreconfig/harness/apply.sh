#!/bin/bash
set -e

ARTIFACT_DIR="${ARTIFACT_DIR:-.}"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONGO_SRC="$ARTIFACT_DIR/mongo-src"

if [ ! -d "$MONGO_SRC" ]; then
    echo "Error: MongoDB source directory not found at $MONGO_SRC"
    exit 1
fi

echo "Applying instrumentation patches..."

REPL_IMPL="$MONGO_SRC/src/mongo/db/repl/replication_coordinator_impl.cpp"
REPL_HEADER="$MONGO_SRC/src/mongo/db/repl/replication_coordinator_impl.h"
QUORUM_CHECKER="$MONGO_SRC/src/mongo/db/repl/check_quorum_for_config_change.cpp"

# Copy trace header to MongoDB source tree
mkdir -p "$MONGO_SRC/src/mongo/db/repl"
cp "$HARNESS_DIR/src/tla_trace.h" "$MONGO_SRC/src/mongo/db/repl/"

# Add #include for trace module to replication_coordinator_impl.cpp
if ! grep -q "#include.*tla_trace.h" "$REPL_IMPL"; then
    sed -i '/#include "mongo\/db\/repl\/check_quorum_for_config_change.h"/a #include "mongo/db/repl/tla_trace.h"' "$REPL_IMPL"
    echo "Added trace header include to replication_coordinator_impl.cpp"
fi

# Add #include for trace module to check_quorum_for_config_change.cpp
if ! grep -q "#include.*tla_trace.h" "$QUORUM_CHECKER"; then
    sed -i '/#include "mongo\/db\/repl\/scatter_gather_runner.h"/a #include "mongo/db/repl/tla_trace.h"' "$QUORUM_CHECKER"
    echo "Added trace header include to check_quorum_for_config_change.cpp"
fi

echo "Instrumentation patches applied successfully"
