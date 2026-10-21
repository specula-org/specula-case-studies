#!/usr/bin/env bash
# CR-2 Phase-2 guest run: build the Asterinas kernel image (incremental,
# reusing the harness build cache in /work/source/target) with a minimal
# initramfs containing the CR-2 reproduction test, boot it under QEMU/KVM,
# and capture the serial output.
#
# Known-good recipe adapted from .specula-output/harness/src/run-container.sh
# (pinned image asterinas/dev:0.18.1-20260926, /dev/kvm, osdk scheme
# specula_memfd).  Run inside the container with /work mounted at the
# asterinas-memfd-seal-mapping-admission run root.
set -euo pipefail

run_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)   # <run-root>
work=/work
harness_dir=$run_dir/.specula-output/harness
cr2_dir=$run_dir/.specula-output/confirmation/CR-2
repro_dir=$run_dir/.specula-output/repro

if [ ! -d "$work/source" ]; then
    echo "expected $work/source to exist" >&2
    exit 1
fi

export CARGO_BUILD_JOBS=4 OSDK_LOCAL_DEV=1
mkdir -p "$cr2_dir/logs" "$cr2_dir/build/initramfs"

cd "$work/source"
echo "== install cargo-osdk (cached) =="
timeout 900 cargo install --path osdk --locked --force \
    >"$cr2_dir/logs/osdk-build.log" 2>&1
echo "== build test binaries =="
gcc -O2 -static -pthread \
    -I "$work/source/test/initramfs/src/regression/common" \
    "$repro_dir/test_bugCR-2_seal_ownership_lifecycle.c" \
    -o "$cr2_dir/build/initramfs/scenarios" 2>"$cr2_dir/logs/scenarios-build.log" \
    || { cat "$cr2_dir/logs/scenarios-build.log" >&2; exit 1; }
gcc -O2 -static "$harness_dir/src/init.c" \
    -o "$cr2_dir/build/initramfs/init"
( cd "$cr2_dir/build/initramfs"
  find . -print0 | cpio --null -o --format=newc \
      >"$cr2_dir/build/initramfs.cpio" 2>/dev/null )
echo "== osdk build =="
cd "$work/source/kernel"
timeout 1800 cargo osdk build --scheme specula_memfd \
    --boot-method=vmm-direct --grub-boot-protocol=multiboot \
    --initramfs "$cr2_dir/build/initramfs.cpio" \
    --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error \
    >"$cr2_dir/logs/kernel-build.log" 2>&1
echo "== osdk run =="
set +e
timeout 900 cargo osdk run --scheme specula_memfd \
    --boot-method=vmm-direct --grub-boot-protocol=multiboot \
    --initramfs "$cr2_dir/build/initramfs.cpio" \
    --kcmd-args=console=ttyS0 --kcmd-args=earlycon --kcmd-args=loglevel=error \
    >"$cr2_dir/logs/guest.log" 2>&1
guest_status=$?
set -e
printf '%s\n' "$guest_status" >"$cr2_dir/logs/guest-exit.txt"
echo "== guest exit: $guest_status =="
tail -25 "$cr2_dir/logs/guest.log"
exit "$guest_status"
