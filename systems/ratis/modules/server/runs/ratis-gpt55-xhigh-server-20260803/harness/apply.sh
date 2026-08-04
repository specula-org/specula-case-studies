#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ -n "${SPECULA_SOURCE_DIR:-}" ]; then
  SOURCE_DIR="$(cd "$SPECULA_SOURCE_DIR" && pwd)"
else
  SOURCE_DIR="$(cd "$OUTPUT_DIR/../../../../../sources/ratis-server" && pwd)"
fi

PATCH="$SCRIPT_DIR/patches/instrumentation.patch"
CHECK_LOG="$(mktemp)"
REVERSE_CHECK_LOG="$(mktemp)"
trap 'rm -f "$CHECK_LOG" "$REVERSE_CHECK_LOG"' EXIT

if [ ! -f "$SOURCE_DIR/mvnw" ]; then
  echo "Expected Apache Ratis source at $SOURCE_DIR, but mvnw was not found." >&2
  exit 1
fi

if [ ! -f "$PATCH" ]; then
  echo "Missing instrumentation patch: $PATCH" >&2
  exit 1
fi

install -D -m 0644 \
  "$SCRIPT_DIR/src/main/java/org/apache/ratis/server/impl/SpeculaTrace.java" \
  "$SOURCE_DIR/ratis-server/src/main/java/org/apache/ratis/server/impl/SpeculaTrace.java"

install -D -m 0644 \
  "$SCRIPT_DIR/src/test/java/org/apache/ratis/SpeculaTraceHarnessTest.java" \
  "$SOURCE_DIR/ratis-server/src/test/java/org/apache/ratis/SpeculaTraceHarnessTest.java"

if git -C "$SOURCE_DIR" apply --check "$PATCH" 2>"$CHECK_LOG"; then
  git -C "$SOURCE_DIR" apply "$PATCH"
  echo "Applied ratis-server instrumentation patch to $SOURCE_DIR"
elif git -C "$SOURCE_DIR" apply -R --check "$PATCH" 2>"$REVERSE_CHECK_LOG"; then
  echo "Instrumentation patch is already applied in $SOURCE_DIR"
else
  echo "Instrumentation patch cannot be applied cleanly and is not already applied." >&2
  cat "$CHECK_LOG" >&2
  cat "$REVERSE_CHECK_LOG" >&2
  echo "Inspect source changes under $SOURCE_DIR before rerunning." >&2
  exit 1
fi

echo "Installed Specula trace harness sources in $SOURCE_DIR"
