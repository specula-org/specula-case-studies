#!/bin/bash
# MC-4 reproduction v4 (this session): cold build of the worktree image and
# boot with the mc4 repro as init, mirroring harness/run.sh (docker dev image,
# KVM, SMP=2). Same invocation shape as run_repro_retry.sh (known-good).
set -u
W=/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-4/worktree
RUN_DIR=/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-4

timeout 2700 docker run --rm --network=host --device=/dev/kvm \
  -v "$W:/work/source" -w /work/source \
  -e RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu \
  -v "$HOME/.cargo/git:/root/.cargo/git" \
  -v "$HOME/.cargo/registry:/root/.cargo/registry" \
  -e CARGO_NET_OFFLINE=true \
  asterinas/dev:0.18.1-20260805 \
  bash -lc 'timeout 2400 make --no-print-directory run_kernel AUTO_TEST=mc4repro TARGET_ARCH=x86_64 SMP=2 MEM=2G ENABLE_KVM=1 QEMU_HOSTFWD=off CONSOLE=hvc0 LOG_LEVEL=error INITRAMFS_SKIP_GZIP=1' \
  > "$RUN_DIR/docker-build-run-v4.log" 2>&1
echo "DOCKER_EXIT=$?" >> "$RUN_DIR/docker-build-run-v4.log"
cp "$W/qemu.log" "$RUN_DIR/guest-run-v4.txt" 2>/dev/null
grep -a "MC4_" "$RUN_DIR/guest-run-v4.txt" > "$RUN_DIR/guest-mc4-markers-v4.txt" 2>/dev/null
echo DONE >> "$RUN_DIR/docker-build-run-v4.log"
