#!/usr/bin/env bash
# test_bugCR-2_run.sh -- host driver for the CR-2 reproduction.
#
# Builds the guest initramfs (init = test_bugCR-2_exfat_resize_tailclear.c)
# inside the Asterinas dev container, boots the prebuilt Specula-instrumented
# kernel under QEMU/KVM with fresh ext2 + exfat images, captures the serial
# log, and checks:
#   T1  - CR2-CLAIM-A verdict line printed by the guest (deadlock watchdog)
#   T2  - ordering of SPECULA_RAW trace events for the ftruncate probe:
#         PageCacheResizeBegin must precede ExfatResizeAllocation
#         (page cache shrunk BEFORE the inode size -- contradicting the
#          exFAT comment at inode.rs:138-139, matching the code)
#
# Usage: bash test_bugCR-2_run.sh   (run from the host; docker + /dev/kvm)
set -euo pipefail

RUN_DIR=/home/chin39/Documents/play/Specula/runs/20260908-150910-0a8c/asterinas-syscall-buffered-file-size-read-consistency
CR2=$RUN_DIR/.specula-output/confirmation/CR-2
IMAGE=${SPECULA_IMAGE:-asterinas/dev:0.18.1-20260805}
CONTAINER=${SPECULA_CONTAINER:-specula-cr2-repro}
LOG=$CR2/repro-guest.log
DOCKER=(docker -H unix:///var/run/docker.sock)

mkdir -p "$CR2"

if ! "${DOCKER[@]}" ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    "${DOCKER[@]}" rm -f "$CONTAINER" >/dev/null 2>&1 || true
    timeout 30 "${DOCKER[@]}" run --rm -d --name "$CONTAINER" --network=host --device=/dev/kvm \
        --mount "type=bind,src=$RUN_DIR,dst=/work" -w /work \
        "$IMAGE" sleep infinity >/dev/null
fi

# --- build guest (inside container) ---
timeout 180 "${DOCKER[@]}" exec "$CONTAINER" bash -lc '
set -euo pipefail
B=/work/.specula-output/confirmation/CR-2/guest
mkdir -p "$B"/root/{dev,proc,tmp,ext2,exfat}
timeout 120 gcc -static -O2 -Wall -Wextra -pthread \
    /work/.specula-output/repro/test_bugCR-2_exfat_resize_tailclear.c -o "$B"/root/init
cd "$B"/root
find . -print0 | cpio --null -o --format=newc > "$B"/initramfs.cpio
cd "$B"
truncate -s 128M ext2.img
mkfs.ext2 -q -F -b 4096 ext2.img
truncate -s 128M exfat.img
mkfs.exfat -c 4096 exfat.img
echo "guest build done"
'

# --- boot (inside container) ---
set +e
timeout 300 "${DOCKER[@]}" exec "$CONTAINER" bash -lc '
set -euo pipefail
B=/work/.specula-output/confirmation/CR-2/guest
K=/work/.specula-output/harness/build/kernel-direct/asterinas-osdk-bin.qemu_elf
cd "$B"
exec timeout 240 qemu-system-x86_64 -enable-kvm -machine q35,kernel-irqchip=split \
    -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot -display none -monitor none -serial stdio \
    -nic none -kernel "$K" -initrd "$B"/initramfs.cpio \
    -append "rdinit=/init earlycon loglevel=4 console=ttyS0" \
    -drive if=none,format=raw,id=x0,file="$B"/ext2.img \
    -drive if=none,format=raw,id=x1,file="$B"/exfat.img \
    -device virtio-blk-pci,drive=x0,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device virtio-blk-pci,drive=x1,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04
' > "$LOG" 2>&1
RC=$?
set -e
echo "qemu exit code: $RC (124/143 = outer timeout, expected when the guest deadlocks)"

# --- host-side verdict checks ---
echo "==== guest verdict lines ===="
grep -E "^(T0|T1|T1b|T2|CR2)" "$LOG" || true

echo "==== T2 ordering check (PageCacheResizeBegin vs ExfatResizeAllocation within probe window) ===="
python3 - "$LOG" <<'PY'
import json, re, sys
text = open(sys.argv[1], errors="replace").read()
begin = text.index("T2_PROBE_BEGIN")
end = text.index("T2_PROBE_END")
window = text[begin:end]
events = []
for m in re.finditer(r'SPECULA_RAW (\{.*\})', window):
    try:
        ev = json.loads(m.group(1))
        events.append((ev["event"], ev["start"]))
    except Exception:
        pass
order = [e for e in events if e[0] in ("PageCacheResizeBegin", "ExfatResizeAllocation")]
for name, ts in order:
    print(f"  {name} @ {ts}")
names = [n for n, _ in order]
if "PageCacheResizeBegin" in names and "ExfatResizeAllocation" in names:
    if names.index("PageCacheResizeBegin") < names.index("ExfatResizeAllocation"):
        print("T2_CHECK: page cache shrunk BEFORE inode allocation/size update")
        print("  -> contradicts exFAT comment (inode.rs:138-139: shrink updates page_cache")
        print("     size AFTER inode size); matches the actual code at inode.rs:1491-1494")
        print("CR2-CLAIM-B: CONFIRMED (runtime trace)")
    else:
        print("T2_CHECK: inode-first order observed -- comment would hold, code differs")
        print("CR2-CLAIM-B: NOT CONFIRMED")
else:
    print("T2_CHECK: trace events missing")
PY
