#!/usr/bin/env bash
# MC-6 fix verification: boot the PATCHED kernel (/tmp/mc6-fixval build) with
# the same guest test as test_bugMC-6_run.sh. Expect MC6_RESULT OK.
set -euo pipefail
RUN_DIR=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency
FIXVAL=/tmp/mc6-fixval
IMAGE=${SPECULA_IMAGE:-asterinas/dev:0.18.1-20260805}
GUEST_LOG="$FIXVAL/build/verify-guest.log"

timeout 600 docker run --rm --device=/dev/kvm \
    --mount "type=bind,src=$FIXVAL,dst=/work" \
    --mount "type=bind,src=$RUN_DIR,dst=/run_ro,readonly" \
    -w /work \
    "$IMAGE" bash -euo pipefail -c '
        set -x
        mkdir -p /work/build/verify-root/{dev,proc,tmp,ramfs}
        gcc -static -O2 -Wall -Wextra \
            /run_ro/.specula-output/repro/test_bugMC-6_ramfs_empty_pwrite.c \
            -o /work/build/verify-root/test_mc6
        gcc -static -O2 -Wall -Wextra \
            /run_ro/.specula-output/repro/test_bugMC-6_init.c \
            -o /work/build/verify-root/init
        (cd /work/build/verify-root && find . -print0 | cpio --null -o --format=newc > /work/build/verify-initramfs.cpio)
        timeout 420 qemu-system-x86_64 -enable-kvm -machine q35,kernel-irqchip=split \
            -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot \
            -display none -monitor none -serial stdio \
            -nic none \
            -kernel /work/build/kernel-direct/asterinas-osdk-bin.qemu_elf \
            -initrd /work/build/verify-initramfs.cpio \
            -append "rdinit=/init earlycon loglevel=4 console=ttyS0" \
            -device isa-debug-exit,iobase=0xf4,iosize=0x04
    ' > "$GUEST_LOG" 2>&1 || true

echo "=== guest log: $GUEST_LOG ==="
grep -aE "MC6_REPRO|MC6_SUMMARY|MC6_RESULT|Kernel panic|BUG" "$GUEST_LOG" | head -60 || true
if grep -aq "MC6_RESULT OK" "$GUEST_LOG"; then
    echo "FIX-VERIFY: PASS (contract honored)"
elif grep -aq "MC6_RESULT BUG_TRIGGERED" "$GUEST_LOG"; then
    echo "FIX-VERIFY: FAIL (bug still triggers)"
else
    echo "FIX-VERIFY: INCONCLUSIVE (see full log)"
fi
