#!/usr/bin/env bash
set -euo pipefail

# Level 0 only. This preserves the model counterexample's order: queue the
# blocked signal before epoll registration, then change the existing signalfd
# mask. It uses no injected kernel state or source modification.

repo=/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/confirmation/MC-5/worktree
repro_dir=/home/chin39/Documents/play/Specula/runs/asterinas-fd-epoll-pipeline-20260811T164254Z/asterinas-fd-epoll/.specula-output/repro

if [[ -n "${MC5_OSDK_BIN_DIR:-}" ]]; then
    export PATH="$MC5_OSDK_BIN_DIR:$PATH"
fi
if [[ -n "${MC5_QEMU_BIN_DIR:-}" ]]; then
    export PATH="$MC5_QEMU_BIN_DIR:$PATH"
fi
if [[ -n "${MC5_OVMF:-}" ]]; then
    export OVMF="$MC5_OVMF"
fi
if [[ -n "${MC5_RUSTUP_TOOLCHAIN:-}" ]]; then
    toolchain_bin=$(dirname "$(rustup which --toolchain "$MC5_RUSTUP_TOOLCHAIN" cargo)")
    export PATH="$toolchain_bin:$PATH"
fi
if [[ -z "${VDSO_LIBRARY_DIR:-}" ]]; then
    printf '%s\n' 'MC5_CE_ENV_ERROR VDSO_LIBRARY_DIR must name the checked-out linux_vdso tree' >&2
    exit 64
fi

initramfs=$(timeout 10m nix-build --no-out-link \
    "$repro_dir/test_bugMC-5_exact_counterexample.nix")
target_dir=${MC5_CARGO_TARGET_DIR:-$(mktemp -d /tmp/mc5-exact-ce-cargo-target.XXXXXX)}
init_path=/test/io/mc5/test_bugMC-5-exact-counterexample

printf 'MC5_CE_BUILD initramfs=%s smp=2 target=%s\n' "$initramfs" "$target_dir"
cd "$repo/kernel"
exec timeout 20m env SMP=2 CARGO_TARGET_DIR="$target_dir" \
    cargo osdk run \
    --target-arch x86_64 \
    --boot-method qemu-direct \
    --grub-boot-protocol multiboot2 \
    --qemu-args='-accel kvm' \
    --kcmd-args="init=$init_path" \
    --kcmd-args='loglevel=error' \
    --kcmd-args='earlycon' \
    --kcmd-args='console=hvc0' \
    --initramfs "$initramfs" \
    --init-args=mc5
