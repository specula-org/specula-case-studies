#!/usr/bin/env bash
# CR-4 reproduction driver.
#
# Runs the CR-4 fixture three ways, all bounded by outer timeouts:
#   1. Linux smoke control: the same flock workload on an uninstrumented
#      Linux container, proving the fixture itself is sound (every flock
#      succeeds, every round completes, no hang).
#   2. Guest runs (3 boots): boots the prebuilt instrumented Asterinas kernel
#      (pin 0c6053709 + the campaign's reviewed trace instrumentation, the
#      exact tree audited in investigation.md) in the campaign container with
#      KVM, 2 vCPUs, 2G RAM, and runs the fixture as /init. The fixture
#      reports whether the request-clone Drop ever drained a queued waiter
#      (CR-4 signature) and how many futile re-enqueue cycles occurred.
#
# A fired guest timeout is recorded as evidence, never retried silently.
set -uo pipefail

REPRO_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
RUN_DIR=${SPECULA_CR4_RUN_DIR:-$REPRO_DIR/$(basename "$0" .sh)-run-$(date -u +%Y%m%dT%H%M%S)}
mkdir -p "$RUN_DIR"
echo "run dir: $RUN_DIR"

docker=(sudo -n docker -H unix:///var/run/docker.sock)
container=specula-flock-harness-20261005
image=asterinas/kernel-dev:0.18.1-20260926

# Build the static fixture inside the campaign container (same gcc the harness uses).
"${docker[@]}" exec "$container" mkdir -p /cr4
"${docker[@]}" cp "$REPRO_DIR/test_bugCR-4_drop_drain.c" "$container:/cr4/fixture.c"
if ! "${docker[@]}" exec "$container" gcc -O2 -static -pthread -o /cr4/init /cr4/fixture.c \
    > "$RUN_DIR/fixture-build.log" 2>&1; then
    echo "FIXTURE BUILD FAILED:"; cat "$RUN_DIR/fixture-build.log"; exit 2
fi
"${docker[@]}" cp "$container:/cr4/init" "$RUN_DIR/init"

# 1. Linux smoke control of the fixture logic (uninstrumented path).
timeout 180 "${docker[@]}" run --rm --cpus 2 --memory 2g --pids-limit 512 \
    --tmpfs /tmp:rw,nosuid,size=64m -v "$RUN_DIR:/w:ro" -w /tmp \
    "$image" timeout 120 /w/init > "$RUN_DIR/linux-smoke.log" 2>&1
smoke=$?
echo "== linux smoke exit $smoke"; grep -E "CR4_" "$RUN_DIR/linux-smoke.log" || true
if [[ $smoke != 0 ]]; then echo "LINUX SMOKE FAILED"; exit 2; fi

# 2. Guest runs: boot the instrumented kernel with the fixture as initramfs /init.
for boot in 1 2 3; do
    "${docker[@]}" exec "$container" bash -c '
        set -e; rm -rf /cr4/root; mkdir -p /cr4/root
        cp /cr4/init /cr4/root/init
        cd /cr4/root && find . -print0 | cpio --null -o --format=newc > /cr4/initramfs.cpio'
    timeout 420 "${docker[@]}" exec "$container" bash -c '
        export CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1
        export PATH="/source/target/harness-osdk/debug:$PATH"
        cd /source/kernel
        timeout 390 cargo osdk run --scheme flock --initramfs /cr4/initramfs.cpio \
            --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error' \
        > "$RUN_DIR/guest-boot$boot.log" 2>&1
    status=$?
    echo "== guest boot $boot exit $status"
    grep -E "CR4_" "$RUN_DIR/guest-boot$boot.log" | tee "$RUN_DIR/guest-boot$boot.summary" || true
    if [[ $status == 124 ]]; then
        echo "GUEST BOOT $boot TIMED OUT (recorded as evidence)"
    fi
done

echo "== aggregate =="
grep -h "CR4_RESULT\|CR4_NO_DRAIN\|CR4_SIGNATURE\|CR4_BUFFER" "$RUN_DIR"/guest-boot*.summary || true
echo "DONE $RUN_DIR"
