#!/usr/bin/env bash
# MC-3 repro: ExFAT stale write preparation permits false success and
# inconsistent extents.
#
# Counterexample MC_hunt_s2_exfat_extent_bfs1.out: two extending pwrite64
# writers race across exFAT write_at's prepare/release/reacquire protocol
# (kernel/core/src/fs/fs_impls/exfat/inode.rs). The higher extender (t1,
# off 8192) prepares the page cache to 12288 and releases the write guard;
# the lower extender (t0, off 4096) then prepares, lowering the VMO capacity
# to 8192 (page_cache/mod.rs resize). t1's copy at 8192 is silently clamped
# to 0 bytes by Vmo::write (vmo/mod.rs), yet write_at publishes its saved
# new_size=12288 and returns the full requested count 4096.
#
# Levels executed here (escalation ladder):
#   L1  — timing-only, unpatched kernel (already run: build/guest-L1.log,
#         500 trials, not triggered).
#   L3  — minimal code modification: prctl-armed busy-wait inside write_at
#         at the exact CE window (after ExfatWriteAtReleasePreparation,
#         before reacquiring the guard). Timing-only; no logic change.
#   L3R — same hook, opposite publish order (file size regresses below an
#         already-completed write).
#
# Guest program: repro/guest_mc3.c (compiled static into initramfs-L3{,R}).
# Kernel: confirmation/MC-3/kernelhook (patched copy of the worktree with
#         repro/mc3-kernel-hook.patch applied; renamed from kernel-src because
#         the component-system path heuristic panics on any directory whose
#         name contains "src/"), built to confirmation/MC-3/build/kernel-l3
#         (see build/kernel-build-l3.log). Patch audit in investigation.md:
#         exactly 3 files differ, timing hook only, default disarmed.
#
# Requires: docker container `specula-mc3` (image asterinas/dev:0.18.1-20260901)
# with the run dir mounted at /work and /dev/kvm passed through.
#
# Usage: bash test_bugMC-3_exfat_stale_prepare.sh [L3|L3R|both]
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(dirname "$HERE")
BLD=$OUT/confirmation/MC-3/build
CONTAINER=${SPECULA_CONTAINER:-specula-mc3}
MODE=${1:-both}

run_guest() {
    local initrd=$1 tag=$2 log=$3
    docker exec "$CONTAINER" bash -c "
        cd /work/.specula-output/confirmation/MC-3/build &&
        exec timeout 150 qemu-system-x86_64 -enable-kvm -machine q35,kernel-irqchip=split \
            -cpu Icelake-Server,+x2apic -smp 2 -m 2G -no-reboot -display none \
            -monitor none -serial stdio \
            -nic none -kernel kernel-l3/asterinas-osdk-bin.qemu_elf -initrd $initrd \
            -append 'rdinit=/init earlycon loglevel=4 console=ttyS0' \
            -drive if=none,format=raw,id=x1,file=exfat.img \
            -device virtio-blk-pci,drive=x1,disable-legacy=on,disable-modern=off,event_idx=off,indirect_desc=off \
            -device isa-debug-exit,iobase=0xf4,iosize=0x04" > "$log" 2>&1 || true
}

case "$MODE" in
    L3)  run_guest initramfs-L3.cpio  L3  "$BLD/guest-L3.log" ;;
    L3R) run_guest initramfs-L3R.cpio L3R "$BLD/guest-L3R.log" ;;
    both)
        run_guest initramfs-L3.cpio  L3  "$BLD/guest-L3.log"
        run_guest initramfs-L3R.cpio L3R "$BLD/guest-L3R.log"
        ;;
    *) echo "usage: $0 [L3|L3R|both]" >&2; exit 2 ;;
esac

grep -h "MC3_BEGIN\|MC3_RESULT\|MC3_VERDICT" "$BLD"/guest-L3*.log || true
