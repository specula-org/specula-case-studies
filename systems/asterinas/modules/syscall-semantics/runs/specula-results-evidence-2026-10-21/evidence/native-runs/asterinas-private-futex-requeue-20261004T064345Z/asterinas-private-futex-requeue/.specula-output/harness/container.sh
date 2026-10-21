#!/usr/bin/env bash
set -euo pipefail
cd /work/source
export CARGO_BUILD_JOBS=2 OSDK_LOCAL_DEV=1 RUSTUP_TOOLCHAIN=nightly-2026-07-21
export CARGO_TARGET_DIR=/work/.specula-output/harness/build/target
export OSTD_TASK_STACK_SIZE_IN_PAGES=64
h=/work/.specula-output/harness
if [[ ${SPECULA_REUSE_KERNEL:-0} != 1 ]]; then
    mkdir -p "$h/build/initramfs/sbin" "$h/build/initramfs/dev" "$h/build/initramfs/proc" "$h/build/initramfs/tmp"
    timeout 1800 cargo build --manifest-path osdk/Cargo.toml --bin cargo-osdk
    export PATH="$CARGO_TARGET_DIR/debug:$PATH"
    timeout 120 make -C test/initramfs/src/regression/process/specula_futex OUTPUT_DIR="$h/build/regression" BUILD_DIR="$h/build/c-tests"
    cp "$h/build/regression/process/specula_futex/scenarios" "$h/build/initramfs/init"
    cd "$h/build/initramfs"
    find . -print0 | cpio --null -o --format=newc > "$h/build/initramfs.cpio"
    cd /work/source/kernel
    export SMP=2 MEM=2G ENABLE_KVM=1 OVMF=off QEMU_DISPLAY=none NETDEV=none
    timeout 1220 python3 "$h/memory-reserve.py"
    timeout 1800 cargo osdk build --initramfs "$h/build/initramfs.cpio" --kcmd-args="rdinit=/init" --kcmd-args="console=ttyS0" --kcmd-args="earlycon" --kcmd-args="loglevel=error" --kcmd-args="FUTEX_CASE=1"
fi
for scenario in ${SPECULA_CASES:-1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18}; do
    # Repackage only the boot arguments. The compiled kernel and initramfs stay fixed.
    root="$h/build/run-iso-root"
    mkdir -p "$root/boot/grub"
    cp "$CARGO_TARGET_DIR/osdk/iso_root/boot/asterinas-osdk-bin" "$root/boot/"
    cp "$CARGO_TARGET_DIR/osdk/iso_root/boot/initramfs.cpio.gz" "$root/boot/"
    sed -E "s/FUTEX_CASE=[0-9]+/earlycon FUTEX_CASE=$scenario/" \
        "$CARGO_TARGET_DIR/osdk/iso_root/boot/grub/grub.cfg" > "$root/boot/grub/grub.cfg"
    iso="$h/build/case-$scenario.iso"
    timeout 120 grub-mkrescue -o "$iso" "$root" > "$h/logs/package-$scenario.log" 2>&1
    sha256sum "$iso" "$root/boot/asterinas-osdk-bin" "$root/boot/initramfs.cpio.gz" > "$h/logs/images-$scenario.sha256"
    status=0
    timeout -k 10 120 qemu-system-x86_64 -machine q35,accel=kvm -cpu host \
        -m 2G -smp 2 -bios /root/ovmf/release/OVMF.fd -no-reboot -display none \
        -serial stdio -monitor none -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
        -drive "file=$iso,format=raw,index=2,media=cdrom" > "$h/logs/guest-$scenario.log" 2>&1 || status=$?
    # Asterinas encodes successful isa-debug-exit shutdown as QEMU status 33.
    [[ $status == 0 || $status == 33 ]]
    grep -q "SPECULA_USER_DONE $scenario" "$h/logs/guest-$scenario.log"
    echo "Collected scenario $scenario"
done
