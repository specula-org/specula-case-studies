#!/usr/bin/env bash
set -euo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FRR_SRC="${FRR_SRC:-/home/ubuntu/network-control-plane/workspaces/frr/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850}"
PATCH_FILE="$HARNESS_DIR/patches/instrumentation.patch"

if ! git -C "$FRR_SRC" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	echo "FRR_SRC is not an FRR git work tree: $FRR_SRC" >&2
	exit 1
fi

if [ ! -f "$PATCH_FILE" ]; then
	echo "missing instrumentation patch: $PATCH_FILE" >&2
	exit 1
fi

install -m 0644 "$HARNESS_DIR/src/lib/specula_trace.c" "$FRR_SRC/lib/specula_trace.c"
install -m 0644 "$HARNESS_DIR/src/lib/specula_trace.h" "$FRR_SRC/lib/specula_trace.h"
mkdir -p "$FRR_SRC/tests/topotests"
cp -a "$HARNESS_DIR/src/topotests/specula_route_realization" \
	"$FRR_SRC/tests/topotests/"

if git -C "$FRR_SRC" apply --check "$PATCH_FILE" >/dev/null 2>&1; then
	git -C "$FRR_SRC" apply "$PATCH_FILE"
	echo "applied Specula FRR instrumentation"
elif git -C "$FRR_SRC" apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
	echo "Specula FRR instrumentation already applied"
else
	echo "instrumentation patch does not apply cleanly to $FRR_SRC" >&2
	git -C "$FRR_SRC" apply --check "$PATCH_FILE" >&2 || true
	exit 1
fi
