#!/usr/bin/env bash
set -euo pipefail
HARNESS_DIR=$(cd "$(dirname "$0")" && pwd)
OUTPUT_DIR=$(dirname "$HARNESS_DIR")
RUN_DIR=$(dirname "$OUTPUT_DIR")
IMAGE=${SPECULA_IMAGE:-asterinas/dev:0.18.1-20260901}
DOCKER_SOCKET=${SPECULA_DOCKER_SOCKET:-unix:///var/run/docker.sock}
CONTAINER=${SPECULA_CONTAINER:-specula-buffered-$$}
DOCKER=(docker -H "$DOCKER_SOCKET")
mkdir -p "$HARNESS_DIR/logs"
RUN_STAMP=$(date -u +%Y%m%dT%H%M%SZ)
GUEST_LOG="$HARNESS_DIR/logs/guest-$RUN_STAMP.log"
STATUS_FILE="$HARNESS_DIR/run-status.json"
stage=apply
finish() {
    rc=$?
    python3 - "$STATUS_FILE" "$stage" "$rc" "$GUEST_LOG" <<'PY'
import json,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'stage':sys.argv[2],'exit_code':int(sys.argv[3]),'guest_log':sys.argv[4]},indent=2)+'\n')
PY
    if [[ -z ${SPECULA_CONTAINER:-} ]]; then "${DOCKER[@]}" stop -t 3 "$CONTAINER" >/dev/null 2>&1 || true; fi
}
trap finish EXIT
bash "$HARNESS_DIR/apply.sh"
PATH="$HARNESS_DIR/tools:$PATH"
specula syscall-inputs validate "$HARNESS_DIR/non-tla/contract.json"
if [[ ! -f "$HARNESS_DIR/non-tla/cases.json" ]]; then
    specula syscall-inputs generate --contract "$HARNESS_DIR/non-tla/contract.json" --output "$HARNESS_DIR/non-tla/cases.json"
fi
specula syscall-inputs validate "$HARNESS_DIR/non-tla/cases.json" --contract "$HARNESS_DIR/non-tla/contract.json"
python3 "$HARNESS_DIR/src/emit_cases.py"
stage=container
if [[ -z ${SPECULA_CONTAINER:-} ]]; then
    timeout 30 "${DOCKER[@]}" run --rm -d --name "$CONTAINER" --network=host --device=/dev/kvm \
        --mount "type=bind,src=$RUN_DIR,dst=/work" -w /work/source "$IMAGE" sleep infinity >/dev/null
fi
stage=build-osdk
printf 'Building OSDK and the instrumented kernel; logs: %s\n' "$HARNESS_DIR/logs"
timeout 900 "${DOCKER[@]}" exec -e CARGO_TARGET_DIR=/work/.specula-output/harness/build/osdk-target \
    -e CARGO_NET_GIT_FETCH_WITH_CLI=true -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" \
    "$CONTAINER" bash -lc 'export RUSTUP_TOOLCHAIN=nightly-2026-07-21; OSDK_LOCAL_DEV=1 cargo build --manifest-path osdk/Cargo.toml --bin cargo-osdk -j 8' \
    > "$HARNESS_DIR/logs/osdk-latest.log" 2>&1
stage=build-guest
timeout 180 "${DOCKER[@]}" exec "$CONTAINER" bash /work/.specula-output/harness/build_guest.sh > "$HARNESS_DIR/logs/guest-build-latest.log" 2>&1
stage=build-kernel
timeout 900 "${DOCKER[@]}" exec -w /work/source/kernel -e CARGO_BUILD_JOBS=8 \
    -e CARGO_TARGET_DIR=/work/.specula-output/harness/build/kernel-target -e CARGO_NET_GIT_FETCH_WITH_CLI=true \
    -e http_proxy="${http_proxy:-}" -e https_proxy="${https_proxy:-}" "$CONTAINER" bash -lc \
    'export PATH=/work/.specula-output/harness/build/osdk-target/debug:$PATH; export RUSTUP_TOOLCHAIN=nightly-2026-07-21; cargo osdk build --release --boot-method qemu-direct --initramfs /work/.specula-output/harness/build/initramfs.cpio -o /work/.specula-output/harness/build/kernel-direct' \
    > "$HARNESS_DIR/logs/kernel-latest.log" 2>&1
stage=guest
set +e
timeout 210 "${DOCKER[@]}" exec "$CONTAINER" bash /work/.specula-output/harness/run_guest.sh > "$GUEST_LOG" 2>&1
GUEST_RC=$?
set -e
python3 - "$GUEST_LOG" "$GUEST_RC" <<'PY'
import sys
from pathlib import Path
text=Path(sys.argv[1]).read_text(errors='replace')
rc=int(sys.argv[2])
if rc==124: raise SystemExit('Guest timeout: retain logs and investigate the blocked stack; no automatic retry')
if rc not in (0,33) or 'SPECULA_EXIT 0' not in text: raise SystemExit(f'Guest failed: exit={rc}; see {sys.argv[1]}')
PY
stage=collect
python3 "$HARNESS_DIR/src/collect.py" "$GUEST_LOG"
python3 "$HARNESS_DIR/src/evidence.py" "$HARNESS_DIR/non-tla/raw/observations-$(basename "$GUEST_LOG" .log).json"
specula syscall-inputs validate "$HARNESS_DIR/non-tla/evidence.json" \
    --contract "$HARNESS_DIR/non-tla/contract.json" --cases "$HARNESS_DIR/non-tla/cases.json" --work-dir "$OUTPUT_DIR"
stage=quality
set +e
python3 "$HARNESS_DIR/src/check_quality.py"
QUALITY_RC=$?
set -e
stage=trace-validation
set +e
python3 "$HARNESS_DIR/src/validate_traces.py"
CANONICAL_RC=$?
set -e
python3 "$HARNESS_DIR/src/propose_batch_model.py"
SPECULA_TRACE_SPEC="$HARNESS_DIR/proposed-spec" python3 "$HARNESS_DIR/src/validate_traces.py"
python3 "$HARNESS_DIR/src/write_guide.py"
if [[ $CANONICAL_RC -ne 0 ]]; then
    printf 'The supplied Trace.tla rejects traces; see validation.json and the proposed model patch.\n'
    exit "$CANONICAL_RC"
fi
if [[ $QUALITY_RC -ne 0 ]]; then stage=quality; exit "$QUALITY_RC"; fi
stage=complete
