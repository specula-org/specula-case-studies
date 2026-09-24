#!/usr/bin/env bash
# test_bugMC-7 driver: build the guest initramfs + fixtures and boot the
# known-good Specula kernel under QEMU inside the asterinas/dev container.
# Reuses harness/build/kernel-direct (built from a source tree byte-identical
# to this finding's worktree; see confirmation/MC-7/investigation.md).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUTPUT_DIR=$(dirname "$HERE")
RUN_DIR=$(dirname "$OUTPUT_DIR")
MC7_DIR="$OUTPUT_DIR/confirmation/MC-7"
GUEST="$MC7_DIR/guest"
LOG="$MC7_DIR/repro-guest.log"
KERNEL="$OUTPUT_DIR/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf"
IMAGE=${SPECULA_IMAGE:-asterinas/dev:0.18.1-20260901}
DOCKER_SOCKET=${SPECULA_DOCKER_SOCKET:-unix:///var/run/docker.sock}
CONTAINER=${SPECULA_CONTAINER:-specula-mc7-repro}
DOCKER=(docker -H "$DOCKER_SOCKET")

[[ -f $KERNEL ]] || { echo "missing kernel: $KERNEL" >&2; exit 2; }
mkdir -p "$GUEST/root"

# Fresh fixtures each run (guest writes dirty them).
rm -f "$GUEST/ext2.img" "$GUEST/exfat.img"

if [[ -z ${SPECULA_CONTAINER:-} ]]; then
    "${DOCKER[@]}" rm -f "$CONTAINER" >/dev/null 2>&1 || true
    timeout 30 "${DOCKER[@]}" run --rm -d --name "$CONTAINER" --network=host \
        --device=/dev/kvm --mount "type=bind,src=$RUN_DIR,dst=/work" \
        -w /work/source "$IMAGE" sleep infinity >/dev/null
    trap '"${DOCKER[@]}" stop -t 3 "$CONTAINER" >/dev/null 2>&1 || true' EXIT
fi

echo "== stage: build guest initramfs + fixtures"
timeout 180 "${DOCKER[@]}" exec "$CONTAINER" bash -lc '
set -euo pipefail
cd /work/.specula-output/confirmation/MC-7/guest
mkdir -p root/dev root/proc root/tmp root/ext2 root/exfat
timeout 120 gcc -static -O2 -Wall -Wextra \
    /work/.specula-output/repro/test_bugMC-7_exfat_empty_pwrite.c -o root/init
cd root && find . -print0 | cpio --null -o --format=newc > ../initramfs.cpio && cd ..
truncate -s 128M ext2.img
mkfs.ext2 -F -b 4096 ext2.img >/dev/null
truncate -s 128M exfat.img
mkfs.exfat -c 4096 exfat.img >/dev/null
echo GUEST_BUILD_OK'

echo "== stage: boot QEMU (timeout 180s)"
set +e
timeout 240 "${DOCKER[@]}" exec "$CONTAINER" bash -lc '
set -euo pipefail
cd /work/.specula-output/confirmation/MC-7/guest
exec timeout 180 qemu-system-x86_64 -enable-kvm -machine q35,kernel-irqchip=split \
    -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot -display none -monitor none \
    -serial stdio -nic none \
    -kernel /work/.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf \
    -initrd initramfs.cpio -append "rdinit=/init earlycon loglevel=4 console=ttyS0" \
    -drive if=none,format=raw,id=x0,file=ext2.img \
    -drive if=none,format=raw,id=x1,file=exfat.img \
    -device virtio-blk-pci,drive=x0,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device virtio-blk-pci,drive=x1,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04' > "$LOG" 2>&1
QEMU_RC=$?
set -e
echo "qemu exit: $QEMU_RC (33 = guest poweroff via debug-exit)"

echo "== test markers =="
grep -aE "MC7|SPECULA" "$LOG" || { echo "NO MARKERS — full log tail:"; tail -30 "$LOG"; exit 1; }
