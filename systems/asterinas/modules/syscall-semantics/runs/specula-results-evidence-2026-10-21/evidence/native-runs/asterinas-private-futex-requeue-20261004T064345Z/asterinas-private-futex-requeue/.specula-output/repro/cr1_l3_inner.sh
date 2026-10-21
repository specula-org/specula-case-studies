#!/usr/bin/env bash
# Inner script for the CR-1 Level 3 run -- runs INSIDE the
# asterinas/kernel-dev container, with /work bound to the finding's l3run
# tree (NOT the campaign run dir):
#   /work/source                                        = campaign source
#     0c6053709 + instrumentation + a 6-line timing-only patch in
#     kernel/core/src/process/posix_thread/futex.rs that holds the unlocked
#     fault-retry window open ~200us (tr::stamp() spin) after
#     handle_page_fault, before the loop re-locks and re-loads.
#   /work/.specula-output/harness/build/target          = copy of the
#     campaign's warm build dir (same absolute path as the original build,
#     so cargo rebuilds only the changed crate).
#   /work/.specula-output/repro                         = the CR-1 test.
#
# Steps: compile the test with -DCR1_L3 (phases B/D only, reduced counts),
# rebuild the kernel incrementally, package the ISO, boot under QEMU
# (harness recipe).
set -euo pipefail
export CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1 RUSTUP_TOOLCHAIN=nightly-2026-07-21
export CARGO_TARGET_DIR=/work/.specula-output/harness/build/target
export OSTD_TASK_STACK_SIZE_IN_PAGES=64
export PATH="$CARGO_TARGET_DIR/debug:$PATH"
R=/work/.specula-output/repro/cr1_l3_guest
mkdir -p "$R"
cd "$R"

# 1. Compile the Level 3 variant of the test (fault-window phases only).
gcc -O2 -Wall -static -pthread -DCR1_L3 -o init \
    ../test_bugCR-1_lost_wake_race.c

# 2. Build the initramfs (harness layout; uncompressed cpio).
rm -rf initramfs iso_root
mkdir -p initramfs/dev initramfs/proc initramfs/tmp initramfs/sbin
cp init initramfs/init
( cd initramfs && find . -print0 | cpio --null -o --format=newc ) > initramfs.cpio

# 3. Incrementally rebuild the kernel with the timing patch.
cd /work/source/kernel
timeout 1800 cargo osdk build --initramfs "$R/initramfs.cpio" \
    --kcmd-args="rdinit=/init" --kcmd-args="console=ttyS0" \
    --kcmd-args="earlycon" --kcmd-args="loglevel=error"
kernel="$CARGO_TARGET_DIR/osdk/iso_root/boot/asterinas-osdk-bin"
sha256sum "$kernel" | tee "$R/kernel.sha256"

# 4. Package the ISO from the osdk-produced iso_root.
cd "$R"
mkdir -p iso_root
cp -a "$CARGO_TARGET_DIR/osdk/iso_root/." iso_root/
grub-mkrescue -o cr1_l3.iso iso_root > grub.log 2>&1

# 5. Boot the guest (harness recipe; 33 = clean isa-debug-exit shutdown).
status=0
timeout -k 10 420 qemu-system-x86_64 -machine q35,accel=kvm -cpu host \
    -m 2G -smp 2 -bios /root/ovmf/release/OVMF.fd -no-reboot -display none \
    -serial stdio -monitor none -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    -drive "file=cr1_l3.iso,format=raw,index=2,media=cdrom" > guest.log 2>&1 || status=$?
echo "QEMU_STATUS=$status"
[[ $status == 0 || $status == 33 ]]

# 6. The test must have run to completion.
grep -q "CR1_DONE" guest.log
