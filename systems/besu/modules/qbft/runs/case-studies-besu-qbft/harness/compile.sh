#!/bin/bash
# Compile the QBFT instrumented source (Gradle build).
# Usage: ./compile.sh [besu_root]
set -e
cd "$(dirname "$0")"

BESU_ROOT="${1:-../artifact/besu}"

echo "Compiling instrumented QBFT source..."
cd "$BESU_ROOT"
./gradlew :consensus:qbft-core:compileIntegrationTestJava

echo "Compiled successfully."
