#!/usr/bin/env bash
# test_bugCR-1 driver: builds the guest init + fresh ext2/exfat images inside
# the pinned Asterinas dev container, boots the prebuilt harness kernel with a
# CR-1 initramfs, and captures the serial log.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
OUT_DIR=$(dirname "$SCRIPT_DIR")                 # .specula-output
RUN_DIR=$(dirname "$OUT_DIR")                    # run root, mounted as /work
CR1_DIR="$OUT_DIR/confirmation/CR-1"
IMAGE=${SPECULA_IMAGE:-asterinas/dev:0.18.1-20260901}
DOCKER_SOCKET=${SPECULA_DOCKER_SOCKET:-unix:///var/run/docker.sock}
DOCKER=(docker -H "$DOCKER_SOCKET")
CONTAINER=${SPECULA_CONTAINER:-specula-cr1-$$}
KERNEL="$OUT_DIR/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf"
LOG="$SCRIPT_DIR/test_bugCR-1_guest.log"

[[ -f $KERNEL ]] || { echo "missing prebuilt kernel: $KERNEL" >&2; exit 2; }
mkdir -p "$CR1_DIR/build/root"

finish() {
    rc=$?
    if [[ -z ${SPECULA_CONTAINER:-} ]]; then
        "${DOCKER[@]}" stop -t 3 "$CONTAINER" >/dev/null 2>&1 || true
    fi
    exit $rc
}
trap finish EXIT

timeout 30 "${DOCKER[@]}" run --rm -d --name "$CONTAINER" --network=host --device=/dev/kvm \
    --mount "type=bind,src=$RUN_DIR,dst=/work" -w /work "$IMAGE" sleep infinity >/dev/null

timeout 180 "${DOCKER[@]}" exec "$CONTAINER" bash -lc '
    set -euo pipefail
    CR1=/work/.specula-output/confirmation/CR-1
    mkdir -p $CR1/build/root/{dev,proc,tmp}
    timeout 120 gcc -static -O2 -Wall -Wextra -o $CR1/build/root/init \
        /work/.specula-output/repro/test_bugCR-1_vmo_overdelivery.c
    (cd $CR1/build/root && find . -print0 | cpio --null -o --format=newc > ../initramfs-cr1.cpio)
    truncate -s 128M $CR1/build/ext2.img && mkfs.ext2 -F -q -b 4096 $CR1/build/ext2.img
    truncate -s 128M $CR1/build/exfat.img && mkfs.exfat -c 4096 $CR1/build/exfat.img
'

set +e
timeout 220 "${DOCKER[@]}" exec "$CONTAINER" bash -lc '
    cd /work/.specula-output/confirmation/CR-1/build
    exec timeout 180 qemu-system-x86_64 -enable-kvm -machine q35,kernel-irqchip=split \
        -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot -display none -monitor none \
        -serial stdio -nic none \
        -kernel /work/.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf \
        -initrd initramfs-cr1.cpio \
        -append "rdinit=/init earlycon loglevel=4 console=ttyS0" \
        -drive if=none,format=raw,id=x0,file=ext2.img \
        -drive if=none,format=raw,id=x1,file=exfat.img \
        -device virtio-blk-pci,drive=x0,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
        -device virtio-blk-pci,drive=x1,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04
' > "$LOG" 2>&1
RC=$?
set -e

echo "guest rc=$RC (0/33 = clean poweroff; 124 = timeout) log=$LOG"
grep -a "^CR1" "$LOG" || true
if ! grep -aq "CR1_DONE" "$LOG"; then
    echo "MISSING CR1_DONE MARKER — guest did not finish" >&2
    exit 1
fi
