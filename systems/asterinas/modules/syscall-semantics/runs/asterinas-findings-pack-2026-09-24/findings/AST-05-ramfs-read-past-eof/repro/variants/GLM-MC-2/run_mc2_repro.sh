#!/usr/bin/env bash
# MC-2 confirmation: build & boot the instrumented Asterinas worktree with the
# MC-2 reproduction test, reusing the eval run's warm cargo target cache.
# Mirrors .specula-output/harness/run.sh (docker dev image + /dev/kvm recipe).
set -euo pipefail

W=/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-2/worktree
S=/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/source

cd "$W"
timeout 2400 docker run \
    --rm \
    --network=host \
    --device=/dev/kvm \
    -v "$W:/work/source" \
    -v "$S/target:/work/source/target" \
    -w /work/source \
    -e RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu \
    -v /home/chin39/.cargo/git:/root/.cargo/git \
    -v /home/chin39/.cargo/registry:/root/.cargo/registry \
    -e CARGO_NET_OFFLINE=true \
    asterinas/dev:0.18.1-20260805 \
    bash -lc 'set -euo pipefail; timeout 2200 make --no-print-directory run_kernel AUTO_TEST=mc2repro TARGET_ARCH=x86_64 SMP=2 MEM=2G ENABLE_KVM=1 QEMU_HOSTFWD=off CONSOLE=hvc0 LOG_LEVEL=error INITRAMFS_SKIP_GZIP=1'
