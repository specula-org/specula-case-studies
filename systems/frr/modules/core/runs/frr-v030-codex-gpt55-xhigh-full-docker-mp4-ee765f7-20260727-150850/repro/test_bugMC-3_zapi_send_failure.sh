#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/ubuntu/network-control-plane/repos/specula-v0.3.0/runs/frr-v030-codex-gpt55-xhigh-full-docker-mp4-ee765f7-20260727-150850/frr/.specula-output"
FRR_SRC="$ROOT/confirmation/MC-3/worktree"
IMAGE="${IMAGE:-ncp/frr-replay:ubuntu22-topotest}"
PERSIST_DIR="${PERSIST_DIR:-$ROOT/persist}"
OUT_DIR="$ROOT/repro/mc3-zapi-send-failure"

mkdir -p "$OUT_DIR" "$PERSIST_DIR"

printf 'MC3 reproduction: source=%s\n' "$FRR_SRC"
printf 'MC3 reproduction: image=%s\n' "$IMAGE"
printf 'MC3 ladder: Level 0 baseline normal route advertisement, Level 1 timing-only no target trigger, Level 2 one admissible ZEBRA_ROUTE_ADD send failure.\n'

(cd "$FRR_SRC" && git ls-files -z --cached --others --exclude-standard) > "$ROOT/git-ls-files"

timeout 30m docker run --rm --privileged --network=none \
	-v "$ROOT:/tmp" \
	-v "$FRR_SRC:/root/host-frr:ro" \
	-v "$PERSIST_DIR:/root/persist" \
	-e TOPOTEST_CLEAN=1 \
	-e TOPOTEST_VERBOSE=0 \
	-e TOPOTEST_DOC=0 \
	-e TOPOTEST_SANITIZER=0 \
	"$IMAGE" \
	/bin/bash -lc 'cd /root/persist/frr-build/tests/topotests && pytest -s --junitxml /tmp/repro/mc3-zapi-send-failure/topotests.xml specula_mc3_zapi_send_failure/test_mc3_zapi_send_failure.py::test_mc3_zapi_send_failure_sticks_fib_pending' \
	| tee "$OUT_DIR/output.log"

grep -q 'MC3_RESULT fault_log=MC3_FAIL_ZEBRA_ROUTE_ADD' "$OUT_DIR/output.log"
grep -q 'MC3_RESULT r2_bgp_fib_pending=true' "$OUT_DIR/output.log"
grep -q 'MC3_RESULT r3_received_fault_route=false' "$OUT_DIR/output.log"
grep -q 'MC3_RESULT r2_zebra_route_present=false' "$OUT_DIR/output.log"

printf 'MC3 reproduction: PASS\n'
