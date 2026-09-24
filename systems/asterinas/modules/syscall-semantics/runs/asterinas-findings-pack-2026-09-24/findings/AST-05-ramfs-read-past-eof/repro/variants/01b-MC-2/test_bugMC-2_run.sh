#!/usr/bin/env bash
# Host driver for the MC-2 reproduction.
# Reuses the known-good harness recipe (harness/run.sh / build_guest.sh /
# run_guest.sh): same dev image lineage, same prebuilt kernel ELF, fresh
# ext2/exfat images, same QEMU flags. The kernel's tla_trace instrumentation
# is passive (per-thread preallocated buffer, no-op unless armed via prctl;
# this repro never arms it) and does not alter fs logic, so it is compatible
# with this Level 0/1 test, which observes only syscall-visible behavior.
set -euo pipefail
SPEC_OUT=$(cd "$(dirname "$0")/.." && pwd)
MC2="$SPEC_OUT/confirmation/MC-2"
BUILD="$MC2/build"
RUN_DIR=$(dirname "$SPEC_OUT")
IMAGE=${SPECULA_IMAGE:-asterinas/dev:0.18.1-20260805}
CONTAINER=${SPECULA_CONTAINER:-specula-mc2-$$}
DOCKER=(docker ${DOCKER_HOST:+-H "$DOCKER_HOST"})
mkdir -p "$BUILD"
finish() {
    rc=$?
    if [[ -z ${SPECULA_CONTAINER:-} ]]; then "${DOCKER[@]}" stop -t 3 "$CONTAINER" >/dev/null 2>&1 || true; fi
    exit $rc
}
trap finish EXIT
if [[ -z ${SPECULA_CONTAINER:-} ]]; then
    timeout 30 "${DOCKER[@]}" run --rm -d --name "$CONTAINER" --device=/dev/kvm \
        --mount "type=bind,src=$RUN_DIR,dst=/work" -w /work "$IMAGE" sleep infinity >/dev/null
fi
echo "== build =="
timeout 300 "${DOCKER[@]}" exec "$CONTAINER" bash /work/.specula-output/confirmation/MC-2/guest_build.sh
echo "== run =="
timeout 300 "${DOCKER[@]}" exec "$CONTAINER" bash /work/.specula-output/confirmation/MC-2/guest_run.sh 2>&1 | tee "$BUILD/guest.log"
echo "== done (log: $BUILD/guest.log) =="
