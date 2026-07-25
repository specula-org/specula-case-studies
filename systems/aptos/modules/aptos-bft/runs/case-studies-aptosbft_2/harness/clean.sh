#!/bin/bash
# Revert all instrumentation by checking out the safety-rules source.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARTIFACT_DIR="$(cd "$SCRIPT_DIR/../../artifact/aptos-core" && pwd)"

cd "$ARTIFACT_DIR"
git checkout -- consensus/safety-rules/src/lib.rs \
    consensus/safety-rules/src/safety_rules.rs \
    consensus/safety-rules/src/safety_rules_2chain.rs \
    consensus/safety-rules/src/tests/mod.rs

rm -f consensus/safety-rules/src/tla_trace.rs \
      consensus/safety-rules/src/tests/tla_trace_scenario.rs

echo "Reverted instrumentation."
