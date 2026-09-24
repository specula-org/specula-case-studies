#!/usr/bin/env bash
# test_bugMC-8 driver: builds the guest test + initramfs and boots the already-built
# instrumented Asterinas kernel (harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf,
# built from revision 60494858 + Specula trace instrumentation — logic unchanged, and
# identical ramfs/fs.rs to the MC-8 worktree) inside the same Docker/KVM setup the
# trace harness uses (harness/run.sh). Prints the guest serial log to stdout and to
# repro/test_bugMC-8_guest.log.
set -euo pipefail

REPRO_DIR=$(cd "$(dirname "$0")" && pwd)
OUTPUT_DIR=$(dirname "$REPRO_DIR")
RUN_DIR=$(dirname "$OUTPUT_DIR")
HARNESS_BUILD="$OUTPUT_DIR/harness/build"
IMAGE=${SPECULA_IMAGE:-asterinas/dev:0.18.1-20260901}
DOCKER_SOCKET=${SPECULA_DOCKER_SOCKET:-unix:///var/run/docker.sock}
CONTAINER=${SPECULA_CONTAINER:-specula-mc8-$$}
DOCKER=(docker -H "$DOCKER_SOCKET")
GUEST_LOG="$REPRO_DIR/test_bugMC-8_guest.log"

KERNEL_ELF="$HARNESS_BUILD/kernel-direct/asterinas-osdk-bin.qemu_elf"
[[ -f $KERNEL_ELF ]] || { echo "missing prebuilt kernel: $KERNEL_ELF" >&2; exit 2; }
[[ -f $HARNESS_BUILD/ext2.img ]] || { echo "missing ext2 fixture image" >&2; exit 2; }

cleanup() {
    if [[ -z ${SPECULA_CONTAINER:-} ]]; then
        "${DOCKER[@]}" stop -t 3 "$CONTAINER" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

if [[ -z ${SPECULA_CONTAINER:-} ]]; then
    timeout 30 "${DOCKER[@]}" run --rm -d --name "$CONTAINER" --network=host \
        --device=/dev/kvm --mount "type=bind,src=$RUN_DIR,dst=/work" \
        -w /work/source "$IMAGE" sleep infinity >/dev/null
fi

echo "[mc8] building guest test + initramfs in container $CONTAINER"
timeout 180 "${DOCKER[@]}" exec "$CONTAINER" bash -c '
    set -euo pipefail
    W=/work/.specula-output/repro/mc8_build
    rm -rf "$W"; mkdir -p "$W/root"/{dev,proc,tmp}
    gcc -static -O2 -Wall -Wextra -o "$W/root/init" /work/.specula-output/repro/test_bugMC-8_ramfs_efault_extent.c
    (cd "$W/root" && find . -print0 | cpio --null -o --format=newc > "$W/initramfs.cpio")
' >"$REPRO_DIR/test_bugMC-8_build.log" 2>&1 || {
    echo "[mc8] guest build failed; see test_bugMC-8_build.log" >&2; exit 2; }

echo "[mc8] booting kernel with MC-8 initramfs (timeout 180s)"
set +e
timeout 200 "${DOCKER[@]}" exec "$CONTAINER" bash -c '
    set -euo pipefail
    cd /work/.specula-output
    exec timeout 180 qemu-system-x86_64 -enable-kvm -machine q35,kernel-irqchip=split \
        -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot -display none -monitor none -serial stdio \
        -nic none -kernel harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf \
        -initrd repro/mc8_build/initramfs.cpio \
        -append "rdinit=/init earlycon loglevel=4 console=ttyS0" \
        -drive if=none,format=raw,id=x0,file=harness/build/ext2.img \
        -device virtio-blk-pci,drive=x0,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
        -device isa-debug-exit,iobase=0xf4,iosize=0x04
' | tee "$GUEST_LOG"
rc=${PIPESTATUS[0]}
set -e
echo "[mc8] qemu exited with rc=$rc (0 or 33 expected; log: $GUEST_LOG)"
grep -E "MC8_RESULT|SPECULA_EXIT" "$GUEST_LOG" || { echo "[mc8] no verdict marker in guest log" >&2; exit 1; }
