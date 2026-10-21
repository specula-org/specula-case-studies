#!/usr/bin/env bash
# Reproduction runner for finding MC-5 (exFAT regrown holes read stale bytes).
# Reuses the harness-built instrumented kernel (build/kernel-direct, same source
# revision + instrumentation as confirmation/MC-5/worktree) and boots it in QEMU
# with a FRESH exFAT/ext2 image pair and an initramfs containing only this test.
# Guest runs the pure black-box sequence (Level 0): open+pwrite seed, fsync,
# ftruncate(0), extending pwrite, pread hole.
set -euo pipefail
OUT_DIR=$(cd "$(dirname "$0")" && pwd)                      # .specula-output/repro
WORK=$OUT_DIR/work_mc5
HARNESS=$OUT_DIR/../harness
IMAGE=${SPECULA_IMAGE:-asterinas/dev:0.18.1-20260901}
DOCKER_SOCKET=${SPECULA_DOCKER_SOCKET:-unix:///var/run/docker.sock}
CONTAINER=${SPECULA_MC5_CONTAINER:-specula-mc5-$$}
DOCKER=(docker -H "$DOCKER_SOCKET")
LOG="$WORK/guest-mc5.log"

KERNEL_ELF="$HARNESS/build/kernel-direct/asterinas-osdk-bin.qemu_elf"
[[ -f $KERNEL_ELF ]] || { echo "missing built kernel: $KERNEL_ELF" >&2; exit 2; }

cleanup() { [[ -z ${SPECULA_MC5_CONTAINER:-} ]] && "${DOCKER[@]}" rm -f "$CONTAINER" >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$WORK"
rm -rf "$WORK/root"
mkdir -p "$WORK/root"
mkdir -p "$WORK/root"/{dev,proc,tmp,ramfs,ext2,exfat}

if [[ -z ${SPECULA_MC5_CONTAINER:-} ]]; then
    timeout 30 "${DOCKER[@]}" run --rm -d --name "$CONTAINER" --network=host --device=/dev/kvm \
        --mount "type=bind,src=$(cd "$OUT_DIR/../.." && pwd),dst=/work" -w /work/source \
        "$IMAGE" sleep infinity >/dev/null
fi

# Build the guest binaries, initramfs, and FRESH fs images inside the dev image.
timeout 180 "${DOCKER[@]}" exec "$CONTAINER" bash -lc '
set -euo pipefail
W=/work/.specula-output/repro/work_mc5
R=/work/.specula-output/repro
cd "$W"
timeout 120 gcc -static -O2 -Wall -Wextra "$R/test_bugMC-5_exfat_regrown_hole.c" -o root/test_mc5
timeout 120 gcc -static -O2 -Wall -Wextra "$R/test_bugMC-5_init.c" -o root/init
cd root
find . -print0 | cpio --null -o --format=newc > ../initramfs.cpio
cd ..
truncate -s 128M ext2_mc5.img
mkfs.ext2 -F -b 4096 ext2_mc5.img
truncate -s 128M exfat_mc5.img
mkfs.exfat -c 4096 exfat_mc5.img
' > "$WORK/build.log" 2>&1

# Boot the harness-built kernel with the MC-5 initramfs and fresh images.
set +e
timeout 180 "${DOCKER[@]}" exec "$CONTAINER" bash -lc '
set -euo pipefail
cd /work/.specula-output/repro/work_mc5
exec timeout 150 qemu-system-x86_64 -enable-kvm -machine q35,kernel-irqchip=split \
    -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot -display none -monitor none -serial stdio \
    -nic none -kernel /work/.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf \
    -initrd initramfs.cpio -append "rdinit=/init earlycon loglevel=4 console=ttyS0" \
    -drive if=none,format=raw,id=x0,file=ext2_mc5.img \
    -drive if=none,format=raw,id=x1,file=exfat_mc5.img \
    -device virtio-blk-pci,drive=x0,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device virtio-blk-pci,drive=x1,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
' > "$LOG" 2>&1
RC=$?
set -e
echo "guest exit: $RC  log: $LOG"
grep -aE "MC5|MC-5|SPECULA_|Kernel panic|panic" "$LOG" || true
exit 0
