#!/bin/bash
# MC-4 reproduction: build the instrumented-baseline worktree image and boot it
# with the mc4 repro as init, mirroring harness/run.sh (docker dev image, KVM).
set -u
W=/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-4/worktree
RUN_DIR=/home/chin39/Documents/play/Specula/runs/asterinas-glm53-eval-20260826T035049Z/asterinas-glm53-eval/.specula-output/confirmation/MC-4

timeout 1500 docker run --rm --network=host --device=/dev/kvm \
  -v "$W:/work/source" -w /work/source \
  -e RUSTUP_TOOLCHAIN=nightly-2026-07-21-x86_64-unknown-linux-gnu \
  -v "$HOME/.cargo/git:/root/.cargo/git" \
  -v "$HOME/.cargo/registry:/root/.cargo/registry" \
  -e CARGO_NET_OFFLINE=true \
  asterinas/dev:0.18.1-20260805 \
  bash -lc 'timeout 1200 make --no-print-directory run_kernel AUTO_TEST=mc4repro TARGET_ARCH=x86_64 SMP=2 MEM=2G ENABLE_KVM=1 QEMU_HOSTFWD=off CONSOLE=hvc0 LOG_LEVEL=error INITRAMFS_SKIP_GZIP=1' \
  > "$RUN_DIR/docker-build-run.log" 2>&1
echo "DOCKER_EXIT=$?"
tail -5 "$RUN_DIR/docker-build-run.log"
