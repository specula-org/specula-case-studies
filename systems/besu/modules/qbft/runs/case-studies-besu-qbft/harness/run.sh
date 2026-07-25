#!/bin/bash
# Run the QBFT TLA+ trace integration tests.
# Produces NDJSON trace files in the traces/ directory.
# Usage: ./run.sh [besu_root]
#   besu_root: path to besu checkout (default: ../../artifact/besu)
set -e
cd "$(dirname "$0")"

BESU_ROOT="${1:-../artifact/besu}"
TRACES="$(pwd)/../traces"
mkdir -p "$TRACES"

echo "Running TlaTraceTest integration tests..."
cd "$BESU_ROOT"
./gradlew :consensus:qbft-core:integrationTest \
  --tests "org.hyperledger.besu.consensus.qbft.core.test.TlaTraceTest" \
  --rerun

echo "Copying traces..."
for f in consensus/qbft-core/tla_trace_*.ndjson; do
  base=$(basename "$f" | sed 's/^tla_trace_//' )
  cp "$f" "$TRACES/$base"
  echo "  $(basename "$f") -> traces/$base ($(wc -l < "$f") lines)"
done

echo "Done. Traces in $TRACES"
