#!/usr/bin/env bash
set -euo pipefail
cd /work/source
harness_dir=/work/.specula-output/harness
export CARGO_BUILD_JOBS=4 OSDK_LOCAL_DEV=1
mkdir -p "$harness_dir/logs" "$harness_dir/build/initramfs/proc"
timeout 1800 cargo install --path osdk --locked --force >"$harness_dir/logs/osdk-build.log" 2>&1
timeout 60 gcc -O2 -static -pthread -DSPECULA_TRACE \
    -I test/initramfs/src/regression/common "$harness_dir/src/scenarios.c" \
    -o "$harness_dir/build/initramfs/scenarios"
timeout 60 gcc -O2 -static "$harness_dir/src/init.c" -o "$harness_dir/build/initramfs/init"
(
    cd "$harness_dir/build/initramfs"
    find . -print0 | cpio --null -o --format=newc >"$harness_dir/build/initramfs.cpio"
)
timeout 60 gcc -O2 -static -pthread -I test/initramfs/src/regression/common \
    "$harness_dir/src/scenarios.c" -o "$harness_dir/build/scenarios-linux"
uname -a >"$harness_dir/logs/linux-version.txt"
timeout 120 "$harness_dir/build/scenarios-linux" >"$harness_dir/logs/linux.log" 2>&1
cd kernel
timeout 1800 cargo osdk build --scheme specula_memfd --boot-method=vmm-direct \
    --grub-boot-protocol=multiboot \
    --initramfs "$harness_dir/build/initramfs.cpio" \
    --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error \
    >"$harness_dir/logs/kernel-build.log" 2>&1
set +e
timeout 900 cargo osdk run --scheme specula_memfd --boot-method=vmm-direct \
    --grub-boot-protocol=multiboot \
    --initramfs "$harness_dir/build/initramfs.cpio" \
    --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error \
    >"$harness_dir/logs/guest.log" 2>&1
guest_status=$?
set -e
printf '%s\n' "$guest_status" >"$harness_dir/logs/guest-exit.txt"
if [[ $guest_status == 124 || $guest_status == 137 ]]; then
    echo "The guest exceeded its time budget. Preserve the log and investigate the hang." >&2
    exit "$guest_status"
fi
# The serial completion marker is checked independently by collect.py.
if [[ $guest_status != 0 ]]; then
    echo "OSDK exited with status $guest_status. See harness/logs/guest.log." >&2
    exit "$guest_status"
fi
