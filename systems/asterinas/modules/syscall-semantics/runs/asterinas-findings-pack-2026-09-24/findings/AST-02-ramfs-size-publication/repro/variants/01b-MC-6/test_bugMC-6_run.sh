#!/usr/bin/env bash
# MC-6 repro driver. Builds the guest test + init inside the Asterinas dev
# container, packs a fresh initramfs, and boots the prebuilt instrumented
# kernel (source verified byte-identical to the confirmation worktree at the
# cited site) under QEMU/KVM. Usage: bash test_bugMC-6_run.sh
set -euo pipefail
REPRO_DIR=$(cd "$(dirname "$0")" && pwd)
OUTPUT_DIR=$(dirname "$REPRO_DIR")
RUN_DIR=$(dirname "$OUTPUT_DIR")
IMAGE=${SPECULA_IMAGE:-asterinas/dev:0.18.1-20260805}
BUILD=/work/.specula-output/confirmation/MC-6/build
LOG_DIR="$OUTPUT_DIR/confirmation/MC-6"
mkdir -p "$LOG_DIR"
GUEST_LOG="$LOG_DIR/repro-guest.log"

timeout 600 docker run --rm --device=/dev/kvm \
    --mount "type=bind,src=$RUN_DIR,dst=/work" -w /work \
    "$IMAGE" bash -euo pipefail -c '
        set -x
        mkdir -p '"$BUILD"'/root/{dev,proc,tmp,ramfs}
        gcc -static -O2 -Wall -Wextra \
            /work/.specula-output/repro/test_bugMC-6_ramfs_empty_pwrite.c \
            -o '"$BUILD"'/root/test_mc6
        gcc -static -O2 -Wall -Wextra \
            /work/.specula-output/repro/test_bugMC-6_init.c \
            -o '"$BUILD"'/root/init
        (cd '"$BUILD"'/root && find . -print0 | cpio --null -o --format=newc > '"$BUILD"'/initramfs.cpio)
        timeout 420 qemu-system-x86_64 -enable-kvm -machine q35,kernel-irqchip=split \
            -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot \
            -display none -monitor none -serial stdio \
            -nic none \
            -kernel /work/.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf \
            -initrd '"$BUILD"'/initramfs.cpio \
            -append "rdinit=/init earlycon loglevel=4 console=ttyS0" \
            -device isa-debug-exit,iobase=0xf4,iosize=0x04
    ' > "$GUEST_LOG" 2>&1 || true

echo "=== guest log: $GUEST_LOG ==="
grep -aE "MC6_REPRO|MC6_SUMMARY|MC6_RESULT|MC6_EXIT|Kernel panic|BUG" "$GUEST_LOG" | head -60 || true
if grep -aq "MC6_RESULT BUG_TRIGGERED" "$GUEST_LOG"; then
    echo "REPRO-STATUS: BUG_TRIGGERED"
else
    echo "REPRO-STATUS: NOT_TRIGGERED (see full log)"
fi
