#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARTIFACT="${SPECULA_RATIS_GRPC_ARTIFACT:-/home/ubuntu/specula-ratis-issue123-20260803/sources/ratis-grpc}"
PATCH_FILE="$SCRIPT_DIR/patches/instrumentation.patch"

TRACE_SRC="$SCRIPT_DIR/src/main/java/org/apache/ratis/specula/RatisGrpcTrace.java"
TRACE_DST="$ARTIFACT/ratis-server-api/src/main/java/org/apache/ratis/specula/RatisGrpcTrace.java"
TEST_SRC="$SCRIPT_DIR/src/test/java/org/apache/ratis/grpc/TestSpeculaGrpcTraceHarness.java"
TEST_DST="$ARTIFACT/ratis-test/src/test/java/org/apache/ratis/grpc/TestSpeculaGrpcTraceHarness.java"

if ! git -C "$ARTIFACT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "Artifact is not a git checkout: $ARTIFACT" >&2
  exit 1
fi

if [ ! -f "$PATCH_FILE" ]; then
  echo "Missing instrumentation patch: $PATCH_FILE" >&2
  exit 1
fi

if git -C "$ARTIFACT" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
  echo "Removing previously applied ratis-grpc instrumentation patch"
  git -C "$ARTIFACT" apply --reverse "$PATCH_FILE"
fi

echo "Applying ratis-grpc instrumentation patch"
git -C "$ARTIFACT" apply --check "$PATCH_FILE"
git -C "$ARTIFACT" apply "$PATCH_FILE"

install -d "$(dirname "$TRACE_DST")" "$(dirname "$TEST_DST")"
cp "$TRACE_SRC" "$TRACE_DST"
cp "$TEST_SRC" "$TEST_DST"

echo "Instrumentation applied to $ARTIFACT"
