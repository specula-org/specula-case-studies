#!/usr/bin/env bash
# CR-2 reproduction runner: boots the pinned Asterinas kernel (campaign
# instrumented build, tracing inactive unless the test registers it) in QEMU
# via the reviewed cargo-osdk recipe and runs the C reproduction as PID 1.
set -euo pipefail

repro_dir=$(cd -- "$(dirname -- "$0")" && pwd)
out_dir="$repro_dir/cr2-run-$(date -u +%Y%m%dT%H%M%S)"
mkdir -p "$out_dir"

docker=(sudo -n docker -H unix:///var/run/docker.sock)
container=specula-flock-harness-20261005

# 1. Ship the test source into the container.
"${docker[@]}" exec "$container" mkdir -p /cr2/root
"${docker[@]}" cp "$repro_dir/test_bugCR-2_waiter_retry_lost_wake.c" "$container:/cr2/test.c"

# 2. Build the static fixture binary and the initramfs (same recipe as the
#    reviewed harness build, reused container toolchain; kernel source is
#    untouched, so cargo reuses the verified kernel build).
"${docker[@]}" exec "$container" bash -c '
set -euo pipefail
export CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1
export PATH="/source/target/harness-osdk/debug:$PATH"
rustup override set nightly-2026-07-21 >/dev/null 2>&1 || true
gcc -O2 -static -pthread /cr2/test.c -o /cr2/root/init
mkdir -p /cr2/root/{tmp,proc,sys,dev}
(cd /cr2/root && find . -print0 | cpio --null -o --format=newc > /cr2/initramfs.cpio)
sha256sum /cr2/root/init /cr2/initramfs.cpio
cd /source/kernel
timeout 200 cargo osdk build --scheme flock --initramfs /cr2/initramfs.cpio \
    --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error
' > "$out_dir/build.log" 2>&1 || { echo "BUILD FAILED"; tail -30 "$out_dir/build.log"; exit 2; }
tail -3 "$out_dir/build.log"

# 3. Boot and run, capturing the serial console.
set +e
timeout 240 "${docker[@]}" exec "$container" bash -c '
set -euo pipefail
export CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1
export PATH="/source/target/harness-osdk/debug:$PATH"
cd /source/kernel
timeout 220 cargo osdk run --scheme flock --initramfs /cr2/initramfs.cpio \
    --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error
' > "$out_dir/run.log" 2>&1
status=$?
set -e
printf '%s\n' "$status" > "$out_dir/run.exit"
echo "qemu exit status: $status"
grep -a "CR2-" "$out_dir/run.log" || true
echo "full serial log: $out_dir/run.log"
