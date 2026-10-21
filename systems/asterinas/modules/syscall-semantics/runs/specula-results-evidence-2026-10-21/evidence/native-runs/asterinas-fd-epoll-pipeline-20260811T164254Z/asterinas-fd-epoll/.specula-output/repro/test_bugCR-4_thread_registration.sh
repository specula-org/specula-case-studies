#!/usr/bin/env bash
set -euo pipefail

source_root=/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/CR-4/worktree
repro_dir=/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro
initramfs="$repro_dir/test_bugCR-4_thread_registration-v2.cpio"
build_log="$repro_dir/test_bugCR-4_thread_registration.nix-build.log"
run_log="$repro_dir/test_bugCR-4_thread_registration.asterinas.log"
osdk_target="$repro_dir/test_bugCR-4_thread_registration.osdk-target"
osdk_bin="$osdk_target/debug/cargo-osdk"
toolchain_dir="$repro_dir/test_bugCR-4_pinned-toolchain"
vdso_dir="$repro_dir/test_bugCR-4_linux_vdso"
kernel_bin="$repro_dir/test_bugCR-4_thread_registration.target/x86_64-unknown-none/debug/asterinas-osdk-bin"

if [[ ! -f "$initramfs" || "$repro_dir/test_bugCR-4_thread_registration.c" -nt "$initramfs" || "$repro_dir/test_bugCR-4_thread_registration.nix" -nt "$initramfs" ]]; then
    nix-build --no-out-link "$repro_dir/test_bugCR-4_thread_registration.nix" >"$build_log" 2>&1
    result_path=$(tail -n 1 "$build_log")
    cp --dereference "$result_path" "$initramfs"
fi

if [[ ! -x "$osdk_bin" ]]; then
    (
        cd "$source_root/osdk"
        OSDK_LOCAL_DEV=1 CARGO_NET_OFFLINE=true CARGO_TARGET_DIR="$osdk_target" \
            timeout 10m cargo build --locked --offline
    )
fi

qemu_store=$(nix-build --no-out-link '<nixpkgs>' -A qemu)
if [[ ! -x "$qemu_store/bin/qemu-system-x86_64" ]]; then
    printf 'CR4_ERROR stage=qemu_discovery path=%s\n' "$qemu_store" >&2
    exit 1
fi

mkdir -p "$toolchain_dir"
ln -sfn "$repro_dir/test_bugCR-4_pinned_cargo.sh" "$toolchain_dir/cargo"

cd "$source_root/kernel"
PATH="$qemu_store/bin:$toolchain_dir:$PATH" \
CARGO_NET_OFFLINE=true \
CARGO_TARGET_DIR="$repro_dir/test_bugCR-4_thread_registration.target" \
VDSO_LIBRARY_DIR="$vdso_dir" \
timeout 20m "$osdk_bin" osdk build \
    --boot-method qemu-direct \
    --grub-boot-protocol multiboot2 \
    --initramfs "$initramfs" \
    --kcmd-args='loglevel=error' \
    --kcmd-args='earlycon' \
    --kcmd-args='console=ttyS0' \
    --init-args='-c /test/test_bugCR-4_thread_registration'

if [[ ! -x "$kernel_bin" ]]; then
    printf 'CR4_ERROR stage=kernel_build path=%s\n' "$kernel_bin" >&2
    exit 1
fi

set +e
timeout 120s "$qemu_store/bin/qemu-system-x86_64" \
    -kernel "$kernel_bin" \
    -initrd "$initramfs" \
    -append 'SHELL=/bin/sh LOGNAME=root HOME=/ USER=root PATH=/bin:/benchmark init=/init loglevel=error earlycon console=ttyS0 -- sh -l -c /test/test_bugCR-4_thread_registration' \
    -accel kvm -cpu host -machine q35,kernel-irqchip=split -smp 2 -m 1G \
    -no-reboot -nographic -display none -serial stdio -monitor none \
    -device isa-debug-exit,iobase=0xf4,iosize=0x04 \
    2>&1 | tee "$run_log"
qemu_rc=${PIPESTATUS[0]}
set -e
printf 'CR4_ASTERINAS_QEMU_EXIT=%d\n' "$qemu_rc"

if rg -q 'CR4_RESULT=PERSISTENT_MISS' "$run_log"; then
    exit 42
fi
if rg -q 'CR4_RESULT=DELAYED_WAKEUP' "$run_log"; then
    exit 43
fi
if rg -q 'CR4_RESULT=NO_MISS' "$run_log"; then
    exit 0
fi
exit "$qemu_rc"
